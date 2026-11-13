import AppKit
import Carbon.HIToolbox
import SesameEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panel = Panel()
    private let hotKeys = CarbonHotKeyRegistrar()
    private var settingsWindow: SettingsContainerWindow?

    /// A new combination from Settings is registered at once through the Carbon registrar; the old one stops working.
    private lazy var shortcutControl = ShortcutControl(registrar: hotKeys)

    /// Launch at login: macOS holds the state; the first run registers once (`applyFirstRunDefault`).
    private let loginItem = LoginItem(service: MainAppLoginService())
    private var downloadTask: Task<Void, Never>?

    /// The helper is the one in the app bundle; the model files are under the Sesame folder.
    private let helperClient = HelperClient(
        helper: Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("SesameHelper"),
        textModel: SesameFolder.modelsURL.appendingPathComponent(ModelFiles.all[0].name),
        mmModel: SesameFolder.modelsURL.appendingPathComponent(ModelFiles.all[1].name)
    )

    /// Why indexing is paused right now: the battery, Low Power Mode and the CPU load (real sources), and "you" from the
    /// menu. Memory only.
    private let loadMonitor = LoadMonitor(
        power: IOKitPowerSource(), lowPower: ProcessLowPowerSource(), cpu: HostCPUSampler(), scheduler: TimerScheduler())
    private var quitting = false
    private var quitFinished = false
    private var awaitingTerminateReply = false

    /// The one place that starts and stops the `index` helper (design section 3): it reads settings.json, the model
    /// files, the pause set and Quit each time something changes.
    private lazy var supervisor: HelperSupervisor = HelperSupervisor(host: HelperClientIndexHost(client: helperClient), inputs: { [unowned self] in
        let settings = (try? SettingsFile().read()) ?? Settings()
        return HelperSupervisor.Inputs(
            startPressed: settings.startPressed, indexDeleted: settings.indexDeleted, modelWhole: ModelStateSource.isWhole(),
            pauseReasons: loadMonitor.pauseSet.reasons, quitting: quitting, measuring: speedsStore.isMeasuring)
    }, workRemains: { [unowned self] in
        // The snapshot may predate the helper's last commits: ask for a fresh one, which the restart's own delay waits for.
        status.refresh()
        return status.workRemains
    }, schedule: HelperSupervisor.timerSchedule)

    /// Watches the folders being read and tells the supervisor a sync is needed, 2 s after the last change.
    private lazy var folderWatcher = FolderWatcher(
        source: FSEventsChangeSource(),
        settings: { (try? SettingsFile().read()) ?? Settings() },
        now: { Date() },
        schedule: HelperSupervisor.timerSchedule,
        syncNeeded: { [unowned self] in supervisor.syncNeeded() })

    /// Watches for a drive being unplugged or plugged back in and tells the supervisor a sync is needed.
    private lazy var volumeWatcher = VolumeWatcher(
        source: WorkspaceMountSource(),
        settings: { (try? SettingsFile().read()) ?? Settings() },
        isReadable: VolumeWatcher.canList,
        now: { Date() },
        schedule: HelperSupervisor.timerSchedule,
        syncNeeded: { [unowned self] in supervisor.syncNeeded() },
        mountChanged: { [unowned self] event in
            switch event.kind {
            case .mounted: folderWatcher.volumeMounted(event.path)
            case .unmounted: folderWatcher.volumeUnmounted(event.path)
            }
        })
    private var foldersWatched = false
    private var volumesWatched = false

    /// Applies `WatcherPlan`: both watchers exist while indexing is wanted and the app is not quitting. Called after
    /// launch, Start, a settings change, Delete index and Quit.
    private func applyWatcherPlan() {
        let plan = WatcherPlan.decide(settings: (try? SettingsFile().read()) ?? Settings(), quitting: quitting)
        if plan.folders {
            if foldersWatched {
                folderWatcher.settingsChanged()
            } else {
                folderWatcher.start()
                foldersWatched = true
            }
        } else if foldersWatched {
            folderWatcher.stop()
            foldersWatched = false
        }
        if plan.volumes, !volumesWatched {
            volumeWatcher.start()
            volumesWatched = true
        } else if !plan.volumes, volumesWatched {
            volumeWatcher.stop()
            volumesWatched = false
        }
    }

    /// Quit: indexing stops, both helpers end (killed after 4 s), then the app ends. The index and settings stay.
    private lazy var quitPlan = QuitPlan(
        stopIndexing: { [unowned self] in
            quitting = true
            applyWatcherPlan()
            supervisor.reevaluate()
        },
        shutdownHelpers: { [helperClient] timeout, completion in helperClient.shutdown(timeout: timeout, completion: completion) },
        terminate: { [unowned self] in
            quitFinished = true
            if awaitingTerminateReply {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.terminate(nil)
            }
        })

    private var menuBar: MenuBarController?
    private var menuTask: Task<Void, Never>?

    /// What the panel (and later the menu) read: refreshed in the background, never on the main thread. It reads
    /// through the panel's one index reader.
    private let modelSource = ModelStateSource()
    private lazy var status = StatusCache.live(reader: panel.reader, modelState: { [modelSource] in modelSource.state() })

    /// The setup window, built the first time something asks for it: a launch that shows no setup builds no window, counts
    /// no folder and walks no `~/Developer`. Start indexing writes settings.json and tells the status cache (inside the
    /// window) and the supervisor decides whether the helper runs; the window stays up for the last two steps.
    private lazy var setup = OnDemandSetup(
        make: { [unowned self] in makeSetupWindow() }, show: { [unowned self] window in presentSetup(window) })

    /// The text of a model download failure that still stands (not retried, model not whole); nil otherwise. Main actor.
    private var modelFailure: String?

    /// One Retry per failure; armed wherever `modelFailure` is set. Main actor.
    private var retryGuard = RetryGuard()

    /// The setup's folder list; it exists only once the setup window does. It only counts and times: nothing is sent to
    /// the helper before Start.
    private var setupFolders: SetupFolders?

    /// One bench per launch at most, as soon as the model is whole and no speed is stored: the one-shot helper times the
    /// real pipeline. The supervisor holds the index helper back while it runs (`isMeasuring`) and is told when it ends.
    private lazy var speedsStore: SpeedsStore = SpeedsStore(
        helper: helperClient,
        settingsChanged: { [weak self] in
            self?.status.settingsChanged()
            self?.applyWatcherPlan()
            self?.setupFolders?.refreshEstimates()
            self?.supervisor.reevaluate()
        },
        failed: { [weak self] _ in
            // The store has logged its one line; a helper that waited for the bench may start now.
            self?.supervisor.reevaluate()
        })

    /// The watcher's message is the damaged-model text, which the setup model holds itself; when its refetch fails
    /// too, the failure is shown like a failed launch download: the setup window, built and shown if need be, with Retry.
    private lazy var modelWatcher: ModelWatcher = ModelWatcher(
        onMessage: { [weak self] _ in Task { @MainActor in self?.modelWasDamaged() } },
        onFailure: { [weak self] text in Task { @MainActor in self?.modelDownloadFailed(text) } },
        onFetched: { [weak self] in Task { @MainActor in self?.lookForModelWhole() } })

    /// The one edge detector for "the model became whole", fed by the 2 s menu tick, the launch download, the watcher's
    /// fetch and the setup window; whichever sees the change first runs the hook, once.
    private var wholeEdge = ModelWholeEdge()

    /// Retry reaches the watcher when it waits for one, else starts one launch download; never both. Made with the
    /// setup window, which is the one that shows Retry.
    private var modelRecovery: ModelRecovery?

    /// Delete index: the panel's reader is closed, `reset` goes to the index helper, then the two Caches folders go.
    private lazy var deleteIndexAction = DeleteIndex(
        closeIndex: { [reader = panel.reader] in reader.close() },
        sendReset: { [helperClient] in helperClient.reset() })

    /// The Delete index entry point (the Settings button is task 26). Does nothing unless `confirmed`.
    func deleteIndex(confirmed: Bool) {
        do {
            try deleteIndexAction.run(confirmed: confirmed)
        } catch {
            FileHandle.standardError.write(Data("Sesame: could not delete the index: \(error)\n".utf8))
        }
        indexWasDeleted()
    }

    /// After a Delete index, from the menu path or the Settings button: no reader stays open on the old file (the reader
    /// also reopens by itself when `index.sqlite` is replaced), then the status, watchers and supervisor read again.
    private func indexWasDeleted() {
        panel.reader.close()
        status.settingsChanged()
        applyWatcherPlan()
        supervisor.reevaluate()
        // A failed download still stands (the model is missing): the status says so, and the window with Retry comes back.
        if let text = modelFailure, !ModelStateSource.isWhole() { setup.downloadFailed(text) }
    }

    /// A crash between the settings write and the reset of a Delete index: at launch the reset goes out again.
    private func resumeDeleteIndex() {
        let indexFile = SesameFolder.url.appendingPathComponent("index.sqlite").path
        deleteIndexAction.resumeIfNeeded(
            indexFileExists: FileManager.default.fileExists(atPath: indexFile),
            settings: (try? SettingsFile().read()) ?? Settings())
    }

    /// What the launch shows (the first-window rule): setup until Start indexing was pressed or the index was deleted,
    /// and while the model is not whole.
    static func showsSetup(settings: Settings, modelWhole: Bool) -> Bool {
        SetupFlow.needed(settings: settings, modelWhole: modelWhole)
    }

    /// What this launch does, read from disk now.
    private func launchPlan() -> LaunchPlan {
        let indexFile = SesameFolder.url.appendingPathComponent("index.sqlite").path
        return LaunchPlan.decide(
            settings: (try? SettingsFile().read()) ?? Settings(), modelWhole: ModelStateSource.isWhole(),
            indexFileExists: FileManager.default.fileExists(atPath: indexFile))
    }

    private func needsSetup() -> Bool {
        launchPlan().showsSetup
    }

    /// Something the menu shows may have changed (a pause reason, Start, Delete index): refresh the cached status and
    /// redraw the menu at once from what is cached and the pause set held now.
    private func menuInputsChanged() {
        status.settingsChanged()
        applyWatcherPlan()
        updateMenu()
    }

    /// `model` replaces the cached model state, for a change the cache has not read yet (it refreshes off the main thread).
    private func updateMenu(model: ModelState? = nil) {
        let settings = (try? SettingsFile().read()) ?? Settings()
        var snapshot = status.snapshot()
        if let model { snapshot.model = model }
        menuBar?.update(MenuModel.make(snapshot: snapshot, pauseReasons: loadMonitor.pauseSet.reasons, settings: settings))
    }

    /// The status item and its menu. The cache has one change handler and the panel owns it, so the menu redraws on its
    /// own tick (every 2 s, the first after half a second, when the first read is in) and on each action.
    private func startMenuBar() {
        let actions = MenuActions.live(
            monitor: loadMonitor,
            settingsChanged: { [unowned self] in menuInputsChanged() },
            reevaluate: { [unowned self] in supervisor.reevaluate() },
            resetStall: { [unowned self] in supervisor.resetStall() },
            retryDownload: { [unowned self] in menuRetryDownload() },
            openPanel: { [unowned self] in if !panel.isShown { panel.show() } },
            openSettings: { [unowned self] in showSettings() },
            quit: quitPlan)
        menuBar = MenuBarController(host: SystemStatusItemHost(), actions: actions)
        menuTask = Task { @MainActor [weak self] in
            var wait = Duration.milliseconds(500)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard let self else { return }
                updateMenu()
                status.refresh()
                lookForModelWhole()
                wait = .seconds(2)
            }
        }
    }

    /// The bench runs as soon as the model is whole and there is no photo speed yet, whether or not Start was pressed.
    /// Called before the first supervisor `reevaluate()` at launch, so the index helper never starts beside it.
    private func measureSpeeds() {
        speedsStore.measureIfNeeded(modelWhole: ModelStateSource.isWhole())
    }

    /// The model-whole hook, independent of any window: the first time a look finds the model whole after a look that
    /// found it not whole, the bench runs and the supervisor reads again, once. Looks come from the 2 s menu tick, the
    /// downloads' success and the setup window; the edge makes the hook run once however many of them see the change.
    private func lookForModelWhole() {
        guard wholeEdge.update(isWhole: ModelStateSource.isWhole()) else { return }
        measureSpeeds()
        supervisor.reevaluate()
    }

    /// The person's home as the Sesame folder sees it: `HOME` when set (the kit sets it), else the account's.
    private static func homeFolder() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        return URL(fileURLWithPath: home ?? NSHomeDirectory(), isDirectory: true)
    }

    /// A regular app that Launch Services starts is brought to the front; an accessory app asking for the front
    /// itself is refused (measured: Finder stayed in front). So a launch that shows setup starts as a regular
    /// app, and the policy goes back to accessory when the setup window closes.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(needsSetup() ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try SesameFolder.create()
            loginItem.applyFirstRunDefault()
        } catch {
            FileHandle.standardError.write(Data("Sesame: could not make its folder: \(error)\n".utf8))
        }
        panel.attach(status: status)
        // The panel's relay tells the cache of every `changed` event of the index helper; the supervisor hears of it too.
        status.onHelperChanged = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.supervisor.helperChanged() } }
        }
        panel.attach(helper: helperClient)
        // The supervisor gave up (the death cap, or an idle exit with work left): the menu says so and Resume tries again.
        supervisor.onStalled = { [unowned self] in
            loadMonitor.pauseSet.add(.stalled)
            menuInputsChanged()
            supervisor.reevaluate()
        }
        status.refresh()
        resumeDeleteIndex()
        applyWatcherPlan()
        startMenuBar()
        // The edge's first look: a model that is whole now is no change; one that is not is seen becoming whole later.
        _ = wholeEdge.update(isWhole: ModelStateSource.isWhole())
        // The bench first: the supervisor's first `reevaluate()` (in `AppLifecycle.launch`) must already see `measuring`.
        measureSpeeds()
        AppLifecycle.launch(
            monitor: loadMonitor, settingsChanged: { [unowned self] in menuInputsChanged() },
            reevaluate: { [unowned self] in supervisor.reevaluate() })
        panel.onOpenSettings = { [unowned self] in showSettings() }
        registerHotKey()
        modelWatcher.start()
        startModelDownload(atLaunch: true)
        if needsSetup() {
            showSetup()
        } else if !(settingsWindow?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Every way out of the app (the menu's Quit, Command+Q, logout) goes through the quit plan: the helpers end first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitFinished { return .terminateNow }
        awaitingTerminateReply = true
        quitPlan.begin()
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        downloadTask?.cancel()
        menuTask?.cancel()
        loadMonitor.stop()
        modelWatcher.stop()
    }

    private func showSetup() {
        setup.window().show()
    }

    /// `OnDemandSetup`'s show for a failed download: a window not on screen opens in front (as a regular app, so it can be
    /// the front window; `onClose` sets the policy back); one already on screen is only brought forward.
    private func presentSetup(_ window: SetupWindow) {
        if window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.show()
        }
    }

    /// The model download gave up (the launch download, or the watcher's refetch): the status says "failed" at once and the
    /// setup window opens with the failure line and Retry, with no Start when Start was pressed before.
    private func modelDownloadFailed(_ text: String) {
        modelFailure = text
        retryGuard.recordFailure()
        modelSource.markFailed()
        setup.downloadFailed(text)
        status.refresh()
    }

    /// Retry, from the setup window's button or the menu's item (both come here): the status says "downloading" again, and
    /// the download restarts through `ModelRecovery` (the watcher's retry when it waits for one, else one launch download);
    /// both resume from the `.partial` bytes. Acts once per failure and only while that failure stands and the model is
    /// not whole: a second press (the menu is stale for up to 2 s, or the other button) starts no second fetch beside the
    /// first. The menu is redrawn at once either way, from the model state now, so it leaves the failed state.
    private func modelRetried() {
        if retryGuard.shouldRetry(failureStands: modelFailure != nil, isWhole: ModelStateSource.isWhole()) {
            modelFailure = nil
            modelSource.retried()
            modelRecovery?.retry()
            status.refresh()
        }
        updateMenu(model: modelSource.state())
    }

    /// The menu's "Retry model download": the same path as the setup window's Retry (`SetupModel.retry()` clears the error
    /// line, then `modelRetried()`). A window never built has no error line, so `modelRetried()` runs alone. A second
    /// failure shows the setup window again (`modelDownloadFailed`).
    private func menuRetryDownload() {
        if let model = setup.made?.model {
            model.retry()
        } else {
            modelRetried()
        }
    }

    /// Builds the setup window; `OnDemandSetup` calls this once, the first time something asks for the window.
    private func makeSetupWindow() -> SetupWindow {
        let folders = SetupFolders(
            home: Self.homeFolder(),
            picker: { NSApp.activate(); return FolderPicker.chooseFolders() },
            speeds: { (try? SettingsFile().read().speeds) ?? [:] },
            kindsOn: { (try? SettingsFile().read().kindsOn) ?? [:] },
            modelWhole: { ModelStateSource.isWhole() })
        setupFolders = folders
        // Start goes through the supervisor: it starts the helper, or holds it back while a pause reason holds.
        let window = SetupWindow(
            files: ModelFiles.all, folders: folders, helper: helperClient, status: status,
            onStarted: { [weak self] in
                self?.applyWatcherPlan()
                self?.measureSpeeds()
                self?.supervisor.reevaluate()
            },
            onRetry: { [weak self] in self?.modelRetried() })
        modelRecovery = ModelRecovery(
            setup: window.model, watcher: modelWatcher,
            startLaunchDownload: { [weak self] in self?.startModelDownload(atLaunch: false) })
        // The window's own ticker also sees the change; it goes through the one edge, so the hook never runs twice.
        window.onModelWhole = { [weak self] in self?.lookForModelWhole() }
        window.onClose = { [weak self] in
            guard let self else { return }
            if !panel.isShown, !(settingsWindow?.isVisible ?? false) { NSApp.setActivationPolicy(.accessory) }
        }
        return window
    }

    /// Settings opens fresh (folder rows counted again, the shortcut notice read once) unless it is already on screen.
    private func showSettings(message: String? = nil) {
        if let open = settingsWindow, open.isVisible {
            open.show(message: message)
            return
        }
        let model = SettingsModel(
            sender: SupervisedFolders { [unowned self] in
                applyWatcherPlan()
                supervisor.syncNeeded()
            }, modelWhole: { ModelStateSource.isWhole() },
            onIndexingRequested: { [unowned self] in recoverFromStall() })
        let window = Self.makeSettingsWindow(
            model: model, shortcut: shortcutControl, loginItem: loginItem, deleteIndex: deleteIndexAction)
        window.onClose = { [unowned self] in
            if !panel.isShown, !(setup.made?.isVisible ?? false) { NSApp.setActivationPolicy(.accessory) }
        }
        window.onStarted = { [unowned self] in
            status.settingsChanged()
            applyWatcherPlan()
            measureSpeeds()
            supervisor.reevaluate()
        }
        window.onIndexDeleted = { [unowned self] in indexWasDeleted() }
        settingsWindow = window
        window.show(message: message)
    }

    /// A "Start indexing" or "Re-index" press in Settings while the helper is stalled starts it again, as Resume does.
    /// `recover` works on a copy of the pause set, so the monitor's own set is cleared inside `resetStall`, which runs
    /// first; the status cache and the supervisor then read the cleared set.
    private func recoverFromStall() {
        var pauseSet = loadMonitor.pauseSet
        StallRecovery.recover(
            pauseSet: &pauseSet,
            resetStall: { [unowned self] in
                loadMonitor.pauseSet.remove(.stalled)
                supervisor.resetStall()
            },
            settingsChanged: { [unowned self] in status.settingsChanged() },
            reevaluate: { [unowned self] in supervisor.reevaluate() })
    }

    /// The Settings window over `model`, wired to the shortcut control, the login item and Delete index it is given.
    /// Never shown here. A caller that gives no login item or Delete index gets the unwired ones of `init(model:)`.
    static func makeSettingsWindow(
        model: SettingsModel, shortcut: ShortcutControl, loginItem: LoginItem? = nil, deleteIndex: DeleteIndex? = nil
    ) -> SettingsContainerWindow {
        SettingsContainerWindow(
            model: model, shortcut: shortcut, loginItem: loginItem ?? LoginItem(service: MainAppLoginService()),
            appChoices: AppChoices(), deleteIndex: deleteIndex ?? SettingsContainerWindow.unwiredDeleteIndex())
    }

    private func modelWasDamaged() {
        // The window's error line and Retry go too (E3): the watcher fetches again now, an earlier failure no longer stands.
        setup.window().model.modelWasDamaged()
        modelFailure = nil
        modelSource.retried()
        modelSource.markDamaged()
        // The deleted file makes the model not whole: the edge sees it, so the fetch's end is a change.
        _ = wholeEdge.update(isWhole: ModelStateSource.isWhole())
        status.refresh()
        showSetup()
    }

    /// Fetches whatever is not whole. At launch a file under its real name that fails its check is left to
    /// the watcher, which deletes it and fetches again; two fetches must never write one `.partial`.
    private func startModelDownload(atLaunch: Bool) {
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            if atLaunch, await Self.hasDamagedModelFile() { return }
            let whole = await ModelDownload().start()
            if Task.isCancelled { return }
            guard let self else { return }
            if !whole { modelDownloadFailed(SetupModel.downloadFailedMessage) }
            setup.refreshModelIfMade()
            status.refresh()
            if whole {
                modelFailure = nil
                lookForModelWhole()
            }
        }
    }

    private nonisolated static func hasDamagedModelFile() async -> Bool {
        ModelFiles.all.contains { file in
            let url = SesameFolder.modelsURL.appendingPathComponent(file.name)
            return FileManager.default.fileExists(atPath: url.path) && !ModelFiles.isPresent(file, at: url)
        }
    }

    func hotkeyPressed() {
        Probe.emit("hotkey", 0)
        panel.shortcutPressed()
    }

    /// The shortcut in settings.json (Control+Option+Space until it is changed), through Carbon: no permission is needed.
    /// When neither it nor the default can be registered the app has no other way in, so Settings opens with the reason.
    private func registerHotKey() {
        hotKeys.onPressed = { [unowned self] in hotkeyPressed() }
        let outcome = LaunchHotKey.resolve(combination: shortcutControl.combination, registrar: hotKeys) { [unowned self] text in
            showSettings(message: text)
        }
        if case let .fellBack(live, refused) = outcome {
            shortcutControl.adoptLive(live, refused: refused)
        }
    }
}

/// The Settings model's "send the folders" as the supervisor sees it: a change while paused, deleted or quitting sends
/// nothing; the next resume sends the whole list anyway.
private struct SupervisedFolders: FoldersSender {
    let sync: @MainActor () -> Void

    init(_ sync: @escaping @MainActor () -> Void) { self.sync = sync }

    func sendFolders() {
        MainActor.assumeIsolated { sync() }
    }
}
