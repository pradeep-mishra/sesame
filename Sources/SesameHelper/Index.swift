import Darwin
import Foundation
import SesameEngine

/// The `index` mode: one JSON command per stdin line. A `folders` line reconciles the index in one transaction and
/// is answered with `changed` and, the first time in this process, `walked`; the photos, PDFs, documents and recordings it leaves `pending` are
/// then read in batches. A `preview` line is answered with the picture at pane size (the newest one wins) between units.
/// The helper exits at stdin EOF after its current unit and after 60 s with no command. It reads files only through
/// the engine's `PhotoReader`, `PdfReader`, `DocReader`, `AudioReader` and `PreviewReader` and writes the index only through `IndexStore`.
func runIndex(textModel: String?, mmModel: String?) -> Never {
    signal(SIGPIPE, SIG_IGN)
    // Reading runs at utility QoS so a search stays quick while this works (design section 8).
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
    do { try SesameFolder.create() } catch { quit("could not make the Sesame folder: \(error)") }
    Scratch.removeStale()
    let store: IndexStore
    do { store = try IndexStore() } catch { quit("could not open the index: \(error)") }
    do { try SesameFolder.restrictIndexFiles() } catch { warn("SesameHelper index: could not set the index mode: \(error)") }
    var indexer = Indexer(
        store: store, embedder: EmbedderChoice.make(textModel: textModel.map { URL(fileURLWithPath: $0) }),
        models: textModel.flatMap { text in mmModel.map { (URL(fileURLWithPath: text), URL(fileURLWithPath: $0)) } })
    while true {
        switch indexer.input.next(idleSeconds: Indexer.idleSeconds) {
        case .idle, .end:
            indexer.finish()
        case let .line(text):
            indexer.handle(line: text)
        }
    }
}

/// The step of a unit the helper is in (design sections 3 and 8). A unit is up to 16 files, and a death spends a try only
/// on the file or files whose inputs were in the call that was running, never on a file that was only queued.
enum UnitStep: Equatable, Sendable {
    /// The read (decode, text recognition) of `unit[index]`.
    case read(Int)
    /// One embed call, holding the inputs of `unit[indexes]`.
    case embed([Int])
    /// A preview render, between steps.
    case preview
    /// The models are loading, after the reads and before the first embed call: no file's input is in a model call yet.
    case modelLoad
    /// stdin ended, Quit, `reset`, the app is gone, the idle exit: nothing is in flight.
    case stopping
}

/// The one rule for which files of `unit` are in flight at `step`. It is what `beginAttempt` marks and what the
/// watchdog watches for that step, in the fake path and in the model path alike.
func filesInFlight(_ unit: [IndexStore.PendingPhoto], at step: UnitStep) -> [IndexStore.PendingPhoto] {
    switch step {
    case let .read(index):
        return unit.indices.contains(index) ? [unit[index]] : []
    case let .embed(indexes):
        var seen = Set<Int>()
        return indexes.filter { unit.indices.contains($0) && seen.insert($0).inserted }.map { unit[$0] }
    case .preview, .modelLoad, .stopping:
        return []
    }
}

private struct Indexer {
    static let idleSeconds = 60.0
    /// A batch is up to 25 files that need the same model (design section 3).
    static let batchFiles = 25
    /// A file whose attempt marker reached this was read twice and killed the helper both times (design section 3).
    static let maxTries = 2
    /// An embed unit is at most 16 inputs, or 4 while the panel is open (design section 8).
    static let unitInputsClosed = 16
    static let unitInputsOpen = 4
    /// A file named `crash-always-<n>.jpg` always kills the helper under the fake embedder (design section 9, 1c).
    static func killsFakeHelper(_ name: String) -> Bool {
        guard name.hasPrefix("crash-always-"), name.hasSuffix(".jpg") else { return false }
        let number = name.dropFirst("crash-always-".count).dropLast(".jpg".count)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// How photos get their vectors: the kit's fake, the two model files, or not at all.
    private enum Vectors {
        case fake(FakeEmbedder)
        case model(text: URL, mm: URL)
        case none
    }

    var store: IndexStore?
    var input = IndexInput()
    /// The size in force: set by each `panel` line, applied to the batch in flight.
    private var unitSize = Indexer.unitInputsClosed
    private let vectors: Vectors
    /// The preview renderer and its scratch folder, `$TMPDIR/Sesame-<pid>`, removed when the helper exits.
    private let scratch = Scratch()
    private let previews: PreviewReader
    private var hasWalked = false
    /// The folders of the latest `folders` line, by their real paths: the rules are asked again about each file (by its
    /// real path) just before it is read.
    private var picks: [HelperFolder] = []
    /// Set while a batch runs: stdin ended, or a newer `folders` line changed the queue.
    private var ending = false
    private var requeue = false
    private var modelFailed = false
    /// What a Vision failure does in this helper run (`RecognitionPolicy`), and the files it failed on and skipped, so
    /// a later `folders` line of the same run does not read them again and count a second failed run.
    private var recognition = RecognitionPolicy()
    private var visionFailed = Set<Int64>()
    /// Audio steps of different files whose model call threw one after another, with no success between (see `modelStepFailed`).
    private var failedInARow: [IndexStore.PendingPhoto] = []
    /// The attempt markers on the index right now, which are the files in flight of the step in progress (see `enter`).
    private var marked: [IndexStore.PendingPhoto] = []
    /// Runs while a batch does; always watches the same files as `marked`.
    private var watchdog: Watchdog?

    private struct MarkerNotWritten: Error {}

    /// The models of a batch, made and freed through a `Batcher` (`makeBatcher`): the text model for text pieces, the
    /// picture encoder (with its text model) for photos and scan pages, the same with its audio tower for audio windows.
    private final class Models {
        private let text: URL?
        private let mm: URL?
        private(set) var textEmbedder: LlamaEmbedder?
        private(set) var picture: PhotoEmbedder?
        private(set) var audio: PhotoEmbedder?

        init(text: URL?, mm: URL?) {
            self.text = text
            self.mm = mm
        }

        func load(_ model: BatchModel) throws {
            guard let text else { throw LlamaEmbedderError.notLoaded }
            switch model {
            case .text:
                let made = LlamaEmbedder(textModel: text)
                try made.load()
                textEmbedder = made
            case .image:
                guard let mm else { throw LlamaEmbedderError.notLoaded }
                picture = try PhotoEmbedder(textModel: text, mmModel: mm)
            case .audio:
                guard let mm else { throw LlamaEmbedderError.notLoaded }
                audio = try PhotoEmbedder(textModel: text, mmModel: mm, audio: true)
            }
        }

        func unload(_ model: BatchModel) {
            switch model {
            case .text:
                textEmbedder?.unload()
                textEmbedder = nil
            case .image:
                picture?.close()
                picture = nil
            case .audio:
                audio?.close()
                audio = nil
            }
        }
    }

    private let models: Models

    /// A `Batcher` for one batch; its `endBatch` frees whatever the batch loaded.
    private func makeBatcher() -> Batcher {
        let models = models
        return Batcher(load: { try models.load($0) }, unload: { models.unload($0) }, clock: { Date() })
    }

    init(store: IndexStore, embedder: (any Embedder)?, models: (text: URL, mm: URL)?) {
        self.store = store
        previews = PreviewReader(scratch: scratch)
        if let fake = embedder as? FakeEmbedder {
            vectors = .fake(fake)
        } else if let models {
            vectors = .model(text: models.text, mm: models.mm)
        } else {
            vectors = .none
        }
        self.models = Models(text: models?.text, mm: models?.mm)
    }

    mutating func handle(line: String) {
        guard let command = try? HelperProtocol.command(from: line) else {
            warn("SesameHelper index: ignored a line that is not a command")
            return
        }
        switch command {
        case let .panel(open):
            setPanel(open: open)
        case .reset:
            reset()
        case let .folders(folders):
            reconcile(folders)
            work()
            if ending { finish() }
        case let .preview(ticket, file, passage, query):
            preview(ticket: ticket, file: file, passage: passage, query: query)
        default:
            return
        }
    }

    /// Answers one `preview`. A newer `preview` already waiting on stdin cancels this one: no reply is sent for it, and
    /// one that turns up while it is being drawn takes its reply back and deletes its picture.
    private mutating func preview(ticket: Int, file: String, passage: Int?, query: String) {
        settle(.preview)
        if input.newerPreviewQueued() { return }
        let reply = previews.reply(ticket: ticket, file: file, passage: passage, query: query)
        if input.newerPreviewQueued() {
            previews.discard(reply)
            return
        }
        send(.preview(reply))
    }

    /// The embed-unit lever: units of 4 inputs while the panel is open, 16 while it is closed. Answered with `unit`.
    private mutating func setPanel(open: Bool) {
        unitSize = open ? Self.unitInputsOpen : Self.unitInputsClosed
        send(.unit(size: unitSize))
    }

    /// Closes the connection and deletes the index files through `SesameFolder`; nothing is left until the next
    /// `folders` line opens a new index. A batch in flight stops: its queue came from the old index.
    private mutating func reset() {
        settle(.stopping)
        store?.close()
        store = nil
        do { try SesameFolder.deleteIndexFiles() } catch { quit("could not delete the index: \(error)") }
        hasWalked = false
        requeue = true
    }

    /// The open index; opened (and made private) when a `folders` line needs it after a `reset`.
    private mutating func openStore() -> IndexStore {
        if let store { return store }
        do {
            let opened = try IndexStore()
            store = opened
            try SesameFolder.restrictIndexFiles()
            return opened
        } catch { quit("could not open the index: \(error)") }
    }

    /// Every way out of the helper but a death comes here: stdin ended, the idle exit, and `send` when the pipe to the
    /// app is gone. Every marker goes back first.
    mutating func finish() -> Never {
        settle(.stopping)
        store?.close()
        scratch.removeAll()
        exit(0)
    }

    /// The kinds the person switched off in Settings, read from `settings.json` at each use. A missing, unreadable or cut
    /// file, or a missing key, means on: only a stored `false` skips a kind. Photos are not skipped here.
    private static func kindsOff() -> Set<String> {
        guard let on = try? SettingsFile().read().kindsOn else { return [] }
        return Set(["pdf", "doc", "audio", "video"].filter { on[$0] == false })
    }

    private mutating func reconcile(_ folders: [HelperFolder]) {
        let store = openStore()
        // A photo marked `needs_permission` by an earlier run gets one more try, at this run's first `folders` line.
        if !hasWalked {
            do { try store.retryNeedsPermission() } catch {
                warn("SesameHelper index: could not retry the photos that needed permission: \(error)")
            }
        }
        picks = Walker.canonical(folders)
        let walk = Reconcile.photos(in: folders)
        do {
            _ = try store.reconcile(
                walk.found, unreadable: walk.unreadable, vectorSource: LlamaEmbedder.vectorSource,
                walkDoneAt: String(Int(Date().timeIntervalSince1970)), kindsOff: Self.kindsOff())
        } catch {
            warn("SesameHelper index: reconcile failed: \(error)")
            return
        }
        send(.changed)
        if !hasWalked {
            hasWalked = true
            send(.walked)
        }
    }

    // MARK: batches

    /// Reads every `pending` or `partial` file, newest first, in batches of one kind each (photos, or PDFs one step a
    /// file). A file that changed under the read or cannot be taken now is left for the next reconcile and not tried
    /// again in this run.
    private mutating func work() {
        if case .none = vectors { return }
        var skipped = visionFailed
        while !ending, !modelFailed {
            guard let store else { return }
            let queue: [IndexStore.PendingPhoto]
            do {
                // The first file in line decides the kind, so a batch needs one model only.
                guard let head = try store.pendingFiles(limit: 1, excluding: skipped, excludingKinds: Self.kindsOff()).first
                else { return }
                // A later step waits for every first step: a batch is all first steps or all later steps.
                let listed = try store.pendingFiles(kind: head.kind, limit: Self.batchFiles, excluding: skipped)
                queue = Array(listed.prefix { ($0.readTo == nil) == (head.readTo == nil) })
            } catch {
                warn("SesameHelper index: could not list the pending files: \(error)")
                return
            }
            if queue.isEmpty { return }
            // A file whose reads started twice and never ended killed the helper twice: it is not read again.
            let spent = queue.filter { $0.tries >= Self.maxTries }
            if !spent.isEmpty {
                for file in spent {
                    let reason = file.reason == IndexStore.memoryHint ? "needed too much memory" : "damaged"
                    giveUp(on: file, reason: reason, skipped: &skipped)
                }
                continue
            }
            requeue = false
            // A `hint:solo` photo comes first in the queue and is read alone, before any other work.
            let alone = queue.first?.reason == IndexStore.soloHint
            let files = alone ? [queue[0]] : queue
            if queue[0].kind == "photo" { batch(files, skipped: &skipped) } else { stepBatch(files, skipped: &skipped) }
        }
    }

    /// One batch: the picture model is loaded when the first unit needs it and freed when the batch ends.
    private mutating func batch(_ queue: [IndexStore.PendingPhoto], skipped: inout Set<Int64>) {
        var batcher = makeBatcher()
        defer { batcher.endBatch() }
        startWatchdog()
        defer { stopWatchdog() }
        var next = 0
        while next < queue.count, !ending, !requeue, !modelFailed {
            let files = Array(queue[next..<min(next + unitSize, queue.count)])
            next += files.count
            // Whatever way the unit ends but a death, no marker is left on any file (`settle`).
            defer { settle(.stopping) }
            var read: [(file: IndexStore.PendingPhoto, pieces: PhotoPieces)] = []
            var fakeUnit = 0
            for (position, file) in files.enumerated() {
                // A file the rules no longer admit (cloud-only now, or in a hidden, Caches, .app or vendored place) is
                // not opened and keeps its row; the next reconcile decides what happens to it.
                guard rulesStillAdmit(file.path) else {
                    skipped.insert(file.id)
                    continue
                }
                // Only the file being read is marked and watched, never the files queued behind it (`enter`).
                guard enter(files, .read(position), skipped: &skipped) else { continue }
                if case .fake = vectors, Self.killsFakeHelper((file.path as NSString).lastPathComponent) {
                    kill(getpid(), SIGKILL)
                }
                do {
                    var wantBitmap = true
                    if case .fake = vectors { wantBitmap = false }
                    let pieces = try PhotoReader.read(
                        path: file.path, expecting: FileIdentity(size: file.size, mtimeNs: file.mtimeNs, inode: file.inode),
                        wantBitmap: wantBitmap)
                    recognition.recordSuccess()
                    if case let .fake(fake) = vectors {
                        // The fake has no model to batch for, so each file goes read, embed, commit, as in design
                        // section 3; the unit line below still counts the files in the group.
                        let vector = try? fake.embed((file.path as NSString).lastPathComponent, role: .document)
                        commit([(file, pieces)], [vector], skipped: &skipped)
                        fakeUnit += 1
                    } else {
                        read.append((file, pieces))
                    }
                } catch PhotoReadError.unreadable {
                    giveUp(on: file, skipped: &skipped)
                } catch PhotoReadError.cannotOpen {
                    needPermission(file, skipped: &skipped)
                } catch is RecognitionFailed {
                    recognitionFailed(on: file, skipped: &skipped)
                    if modelFailed { break }
                } catch {
                    skipped.insert(file.id)
                }
            }
            if fakeUnit > 0 { logUnit(fakeUnit) }
            if read.isEmpty {
                pollInput()
                continue
            }
            switch vectors {
            case .fake:
                break
            case .model:
                let readFiles = read.map(\.file)
                do {
                    if batcher.loaded != .image {
                        // The last file read is still marked and watched: a death while the models load must not spend a try on it.
                        settle(.modelLoad)
                    }
                    try batcher.use(.image)
                    try models.picture?.embedSteps(read.map { $0.pieces.bitmap! }, unitSize: unitSize) { step in
                        switch step {
                        case let .inFlight(indexes):
                            // Before each model call: the files whose inputs are in it are marked and watched.
                            guard enter(readFiles, .embed(indexes), skipped: &skipped) else { throw MarkerNotWritten() }
                        case let .done(range, made):
                            // The call is over: nothing is in flight while the files are written.
                            settle(.embed([]))
                            logUnit(made.compactMap { $0 }.count)
                            commit(Array(read[range]), made, skipped: &skipped)
                        }
                    }
                } catch is MarkerNotWritten {
                    for item in read { skipped.insert(item.file.id) }
                } catch {
                    warn("SesameHelper index: the model failed: \(error)")
                    if batcher.loaded == nil { modelFailed = true }
                    for item in read { skipped.insert(item.file.id) }
                }
            case .none:
                return
            }
            pollInput()
        }
    }

    /// The memory watchdog runs for a batch; its exit is the death the supervisor restarts the helper from.
    private mutating func startWatchdog() {
        guard let store else { return }
        watchdog = Watchdog(store: store, footprint: { FootprintReader.current() }, exit: { _exit(1) })
        watchdog?.start()
    }

    private mutating func stopWatchdog() {
        watchdog?.stop()
        watchdog = nil
    }

    // MARK: batches of files read in steps (PDFs, documents and audio)

    /// A scan page's picture or an audio window the encoder could not take: the file is damaged, as a photo is.
    private struct PictureRefused: Error {}
    /// A model could not be loaded: the file is left for the next run and no more files are read in this one.
    private struct ModelUnavailable: Error {}

    /// One step of each PDF (up to 30 pages) or document (up to 40 chunks) of the queue, a model loaded when a piece first
    /// needs it and freed when the batch ends. A file with pages or chunks left stays `partial`, and its next step is read
    /// once every first step is.
    private mutating func stepBatch(_ queue: [IndexStore.PendingPhoto], skipped: inout Set<Int64>) {
        var batcher = makeBatcher()
        startWatchdog()
        defer {
            stopWatchdog()
            batcher.endBatch()
        }
        for file in queue {
            if ending || requeue || modelFailed { return }
            if Self.kindsOff().contains(file.kind) { continue }
            switch file.kind {
            case "doc": docStep(file, &batcher, skipped: &skipped)
            case "code": codeStep(file, &batcher, skipped: &skipped)
            case "audio": audioStep(file, &batcher, skipped: &skipped)
            case "video": videoStep(file, &batcher, skipped: &skipped)
            default: pdfStep(file, &batcher, skipped: &skipped)
            }
            pollInput()
        }
    }

    /// Reads the next step of one PDF, embeds its text pieces and then its scan pages (the model is swapped between them)
    /// and stores the whole step in one transaction.
    private mutating func pdfStep(_ file: IndexStore.PendingPhoto, _ batcher: inout Batcher, skipped: inout Set<Int64>) {
        // Whatever way the step ends but a death, no marker is left on the file (`settle`).
        defer { settle(.stopping) }
        guard beginStep(file, skipped: &skipped) else { return }
        do {
            let firstPage = (file.readTo ?? 0) + 1
            let step = try PdfReader.read(
                path: file.path, expecting: FileIdentity(size: file.size, mtimeNs: file.mtimeNs, inode: file.inode),
                firstPage: firstPage, shouldStop: { stopRequested() })
            var texts: [(page: Int, text: String)] = []
            var scans: [(page: Int, words: String, bitmap: PhotoBitmap)] = []
            for page in step.pages {
                switch page.kind {
                case let .text(text): texts.append((page.number, text))
                case let .scan(words, bitmap): scans.append((page.number, words, bitmap))
                }
            }
            if !scans.isEmpty { recognition.recordSuccess() }
            let textVectors: [[Float]]
            let scanVectors: [[Float]]
            switch vectors {
            case let .fake(fake):
                let name = (file.path as NSString).lastPathComponent
                textVectors = try texts.map { try fake.embed($0.text, role: .document) }
                scanVectors = try scans.map { try fake.embed("\(name) page \($0.page)", role: .document) }
            case .model:
                (textVectors, scanVectors) = try modelVectors(file, texts: texts.map(\.text), pictures: scans.map(\.bitmap), &batcher, skipped: &skipped)
            case .none:
                return
            }
            settle(.embed([]))
            if stopRequested() { throw MediaStopped() }
            let passages = (zip(texts, textVectors).map { IndexStore.PagePassage(page: $0.page, text: $0.text, vector: $1) }
                + zip(scans, scanVectors).map { IndexStore.PagePassage(page: $0.page, text: $0.words, vector: $1, modality: "image") })
                .sorted { $0.page < $1.page }
            let stored = try store?.commitStep(
                file, nameWords: step.nameWords, pages: passages, firstPage: firstPage,
                readTo: step.pages.last?.number ?? firstPage, pageCount: step.pageCount)
            if stored == true {
                logUnit(passages.count)
                send(.changed)
            } else {
                skipped.insert(file.id)
            }
        } catch PdfReadError.locked {
            giveUp(on: file, reason: "password-protected", skipped: &skipped)
        } catch PdfReadError.unreadable, is PictureRefused {
            giveUp(on: file, skipped: &skipped)
        } catch PdfReadError.cannotOpen {
            needPermission(file, skipped: &skipped)
        } catch is MarkerNotWritten, is ModelUnavailable, is MediaStopped {
            skipped.insert(file.id)
        } catch is RecognitionFailed {
            recognitionFailed(on: file, skipped: &skipped)
        } catch {
            if !(error is PdfReadError) { warn("SesameHelper index: could not read or store a PDF step: \(error)") }
            skipped.insert(file.id)
        }
    }

    /// Reads the next step of one document, embeds its chunks in the text model and stores the whole step in one
    /// transaction: a `chunk` passage for each, with its UTF-16 offsets.
    private mutating func docStep(_ file: IndexStore.PendingPhoto, _ batcher: inout Batcher, skipped: inout Set<Int64>) {
        // Whatever way the step ends but a death, no marker is left on the file (`settle`).
        defer { settle(.stopping) }
        guard beginStep(file, skipped: &skipped) else { return }
        do {
            let fromChunk = file.readTo ?? 0
            let step = try DocReader.read(
                path: file.path, expecting: FileIdentity(size: file.size, mtimeNs: file.mtimeNs, inode: file.inode),
                fromChunk: fromChunk)
            let vectors: [[Float]]
            switch self.vectors {
            case let .fake(fake):
                vectors = try step.chunks.map { try fake.embed($0.text, role: .document) }
            case .model:
                vectors = try modelVectors(file, texts: step.chunks.map(\.text), pictures: [], &batcher, skipped: &skipped).text
            case .none:
                return
            }
            settle(.embed([]))
            let passages = zip(step.chunks, vectors).map {
                IndexStore.StepPassage(source: "chunk", start: $0.start, end: $0.end, modality: "text", text: $0.text, vector: $1)
            }
            let stored = try store?.commitStep(
                file, nameWords: step.nameWords, first: fromChunk == 0, passages: passages,
                readTo: fromChunk + step.chunks.count, total: step.chunkCount)
            if stored == true {
                logUnit(passages.count)
                send(.changed)
            } else {
                skipped.insert(file.id)
            }
        } catch DocReadError.unreadable {
            giveUp(on: file, skipped: &skipped)
        } catch DocReadError.cannotOpen {
            needPermission(file, skipped: &skipped)
        } catch is MarkerNotWritten, is ModelUnavailable {
            skipped.insert(file.id)
        } catch {
            if !(error is DocReadError) { warn("SesameHelper index: could not read or store a document step: \(error)") }
            skipped.insert(file.id)
        }
    }

    private mutating func codeStep(_ file: IndexStore.PendingPhoto, _ batcher: inout Batcher, skipped: inout Set<Int64>) {
        defer { settle(.stopping) }
        guard beginStep(file, skipped: &skipped) else { return }
        do {
            let fromStretch = file.readTo ?? 0
            let step = try CodeReader.read(
                path: file.path, expecting: FileIdentity(size: file.size, mtimeNs: file.mtimeNs, inode: file.inode),
                fromStretch: fromStretch)
            let vectors: [[Float]]
            switch self.vectors {
            case let .fake(fake):
                vectors = try step.stretches.map { try fake.embed($0.text, role: .document) }
            case .model:
                vectors = try modelVectors(file, texts: step.stretches.map(\.text), pictures: [], &batcher, skipped: &skipped).text
            case .none:
                return
            }
            settle(.embed([]))
            let name = (file.path as NSString).lastPathComponent
            let passages = zip(step.stretches, vectors).map {
                IndexStore.StepPassage(
                    source: "code", start: $0.startLine, end: $0.endLine, modality: "text", text: $0.text, vector: $1, name: name)
            }
            let stored = try store?.commitStep(
                file, nameWords: step.nameWords, first: fromStretch == 0, passages: passages,
                readTo: fromStretch + step.stretches.count, total: step.stretchCount)
            if stored == true {
                logUnit(passages.count)
                send(.changed)
            } else {
                skipped.insert(file.id)
            }
        } catch CodeReadError.damaged {
            giveUp(on: file, skipped: &skipped)
        } catch CodeReadError.tooLarge {
            giveUp(on: file, reason: "too large to read", skipped: &skipped)
        } catch CodeReadError.cannotOpen {
            needPermission(file, skipped: &skipped)
        } catch is MarkerNotWritten, is ModelUnavailable {
            skipped.insert(file.id)
        } catch {
            if !(error is CodeReadError) { warn("SesameHelper index: could not read or store a code step: \(error)") }
            skipped.insert(file.id)
        }
    }

    /// Reads the next step of one audio file (windows that start in up to 500 s), embeds its windows in the audio model and
    /// stores the whole step in one transaction: an `audio` passage for each, with its start and end second and no words.
    /// A decoder that takes nothing from the file gives it up at once; a model call that throws counts one try (`modelStepFailed`).
    private mutating func audioStep(_ file: IndexStore.PendingPhoto, _ batcher: inout Batcher, skipped: inout Set<Int64>) {
        // Whatever way the step ends but a death, no marker is left on the file (`settle`).
        defer { settle(.stopping) }
        guard beginStep(file, skipped: &skipped) else { return }
        do {
            let step = try AudioReader.read(
                path: file.path, expecting: FileIdentity(size: file.size, mtimeNs: file.mtimeNs, inode: file.inode),
                fromSecond: file.readTo ?? 0, scratch: scratch, shouldStop: { stopRequested() })
            let made: [[Float]]
            switch vectors {
            case let .fake(fake):
                let name = (file.path as NSString).lastPathComponent
                made = try step.windows.map { try fake.embed("\(name) window \($0.start)", role: .document) }
            case .model:
                made = try audioVectors(file, step.windows.map(\.samples), &batcher, skipped: &skipped)
            case .none:
                return
            }
            settle(.embed([]))
            if stopRequested() { throw MediaStopped() }
            let passages = zip(step.windows, made).map {
                IndexStore.StepPassage(source: "audio", start: $0.start, end: $0.end, modality: "audio", text: "", vector: $1)
            }
            let stored = try store?.commitStep(
                file, nameWords: step.nameWords, first: file.readTo == nil, passages: passages, readTo: step.readTo,
                total: Int(step.duration.rounded(.up)))
            if stored == true {
                failedInARow.removeAll()
                logUnit(passages.count)
                send(.changed)
            } else {
                skipped.insert(file.id)
            }
        } catch let error as AudioReadError {
            switch error {
            case .unreadable: giveUp(on: file, skipped: &skipped)
            case .cannotOpen: needPermission(file, skipped: &skipped)
            case .changed, .notAdmitted: skipped.insert(file.id)
            }
        } catch is PictureRefused {
            giveUp(on: file, skipped: &skipped)
        } catch is MediaStopped, is MarkerNotWritten, is ModelUnavailable {
            skipped.insert(file.id)
        } catch {
            warn("SesameHelper index: could not embed or store an audio step: \(error)")
            modelStepFailed(file, skipped: &skipped)
        }
    }

    /// The vectors of a step's windows through the audio model, marked and watched while it embeds and not while it loads.
    private mutating func audioVectors(
        _ file: IndexStore.PendingPhoto, _ windows: [[Float]], _ batcher: inout Batcher, skipped: inout Set<Int64>
    ) throws -> [[Float]] {
        guard !windows.isEmpty else { return [] }
        if batcher.loaded != .audio { settle(.modelLoad) }
        do { try batcher.use(.audio) } catch {
            warn("SesameHelper index: the model failed: \(error)")
            modelFailed = true
            throw ModelUnavailable()
        }
        guard enter([file], .embed([0]), skipped: &skipped) else { throw MarkerNotWritten() }
        return try windowVectors(windows)
    }

    /// The vectors of sound windows through the audio model, one stop check after each unit.
    private mutating func windowVectors(_ windows: [[Float]]) throws -> [[Float]] {
        guard let encoder = models.audio else { throw PhotoEmbedderError.failed("the audio model is not loaded") }
        var made = [[Float]?](repeating: nil, count: windows.count)
        try encoder.embedAudio(windows, unitSize: unitSize) { range, vectors in
            for (index, vector) in zip(range, vectors) { made[index] = vector }
            if stopRequested() { throw MediaStopped() }
        }
        guard made.allSatisfy({ $0 != nil }) else { throw PictureRefused() }
        return made.compactMap { $0 }
    }

    /// A model call threw on an audio step. The try the step started stays counted on the file (it leaves `marked`, so `settle`
    /// does not take it back): the second counted try gives the file up, as for Vision, and the run goes on with the next file,
    /// so an older file is never blocked. Three steps of three different files failing one after another mean the model
    /// is down: their tries are put back and the run ends.
    private mutating func modelStepFailed(_ file: IndexStore.PendingPhoto, skipped: inout Set<Int64>) {
        skipped.insert(file.id)
        marked.removeAll { $0.id == file.id }
        watchdog?.watch(marked)
        if file.tries + 1 >= Self.maxTries {
            giveUp(on: file, skipped: &skipped)
            return
        }
        if !failedInARow.contains(where: { $0.id == file.id }) { failedInARow.append(file) }
        if failedInARow.count >= 3 {
            putBack(failedInARow)
            failedInARow.removeAll()
            modelFailed = true
        }
    }

    /// The start of every step: false (the file is left for the next run) when `Rules` no longer admits it or its marker cannot be written.
    private mutating func beginStep(_ file: IndexStore.PendingPhoto, skipped: inout Set<Int64>) -> Bool {
        guard rulesStillAdmit(file.path) else {
            skipped.insert(file.id)
            return false
        }
        return enter([file], .read(0), skipped: &skipped)
    }

    /// Vision failed twice on `file` (`RecognitionRetry`). Either way the failed attempt stays counted on the file (it is
    /// not in `marked` any more, so `settle` does not take the try back): a file Vision fails on in `maxTries` separate
    /// runs, with or without a success earlier in either run, is given up as `damaged` at once, and the run goes on to the
    /// older files. Before that `RecognitionPolicy` decides: `.stopRun` (nothing has succeeded in this run, so Vision may be
    /// down for the whole run) ends the run; `.skipFile` skips only this file. Nothing is logged (the error holds no text
    /// and the log takes none).
    private mutating func recognitionFailed(on file: IndexStore.PendingPhoto, skipped: inout Set<Int64>) {
        skipped.insert(file.id)
        let verdict = recognition.recordFailure()
        marked.removeAll { $0.id == file.id }
        watchdog?.watch(marked)
        if file.tries + 1 >= Self.maxTries {
            giveUp(on: file, skipped: &skipped)
            return
        }
        switch verdict {
        case .stopRun:
            modelFailed = true
        case .skipFile:
            visionFailed.insert(file.id)
        }
    }

    /// The vectors of a step through the real models: text pieces in the text model, then pictures in the picture model.
    /// The file is marked and watched while a model embeds, and not while one loads or is swapped out, so a death then
    /// spends no try on it.
    private mutating func modelVectors(
        _ file: IndexStore.PendingPhoto, texts: [String], pictures: [PhotoBitmap], _ batcher: inout Batcher,
        skipped: inout Set<Int64>
    ) throws -> (text: [[Float]], images: [[Float]]) {
        guard !texts.isEmpty || !pictures.isEmpty else { return ([], []) }
        if batcher.loaded != (texts.isEmpty ? .image : .text) { settle(.modelLoad) }
        do {
            return try batcher.embed(
                text: texts, images: pictures,
                embedText: { pieces in
                    guard enter([file], .embed([0]), skipped: &skipped) else { throw MarkerNotWritten() }
                    defer { if !pictures.isEmpty { settle(.modelLoad) } }
                    guard let embedder = models.textEmbedder else { throw LlamaEmbedderError.notLoaded }
                    return try pieces.map {
                        if stopRequested() { throw MediaStopped() }
                        return try embedder.embed($0, role: .document)
                    }
                },
                embedImages: { bitmaps in
                    guard enter([file], .embed([0]), skipped: &skipped) else { throw MarkerNotWritten() }
                    return try pictureVectors(bitmaps)
                })
        } catch let error where batcher.loaded == nil && !(error is MarkerNotWritten) && !(error is PictureRefused) && !(error is MediaStopped) {
            // Nothing is loaded: a model could not be loaded.
            warn("SesameHelper index: the model failed: \(error)")
            modelFailed = true
            throw ModelUnavailable()
        }
    }

    /// The vectors of pictures through the picture model, one stop check before each picture is encoded and one after each unit.
    private mutating func pictureVectors(_ bitmaps: [PhotoBitmap]) throws -> [[Float]] {
        guard let encoder = models.picture else { throw PhotoEmbedderError.failed("the picture model is not loaded") }
        var made = [[Float]?](repeating: nil, count: bitmaps.count)
        try encoder.embedSteps(bitmaps, unitSize: unitSize) { step in
            switch step {
            case .inFlight:
                if stopRequested() { throw MediaStopped() }
            case let .done(range, vectors):
                for (index, vector) in zip(range, vectors) { made[index] = vector }
            }
        }
        guard made.allSatisfy({ $0 != nil }) else { throw PictureRefused() }
        return made.compactMap { $0 }
    }

    /// Reads the next step of one video (frames and soundtrack windows that start in up to 180 s), embeds its frames in the
    /// picture model and then its windows in the audio model, and stores the whole step in one transaction: a `frame` passage
    /// for each frame (its second as start and end, modality image) and an `audio` passage for each window.
    private mutating func videoStep(_ file: IndexStore.PendingPhoto, _ batcher: inout Batcher, skipped: inout Set<Int64>) {
        // Whatever way the step ends but a death, no marker is left on the file (`settle`).
        defer { settle(.stopping) }
        guard beginStep(file, skipped: &skipped) else { return }
        do {
            let step = try VideoReader.read(
                path: file.path, expecting: FileIdentity(size: file.size, mtimeNs: file.mtimeNs, inode: file.inode),
                fromSecond: file.readTo ?? 0, scratch: scratch, shouldStop: { stopRequested() })
            let frameVectors: [[Float]]
            let windowVectors: [[Float]]
            switch vectors {
            case let .fake(fake):
                let name = (file.path as NSString).lastPathComponent
                frameVectors = try step.frames.map { try fake.embed("\(name) frame \($0.second)", role: .document) }
                windowVectors = try step.windows.map { try fake.embed("\(name) window \($0.start)", role: .document) }
            case .model:
                (frameVectors, windowVectors) = try mediaVectors(file, step, &batcher, skipped: &skipped)
            case .none:
                return
            }
            settle(.embed([]))
            if stopRequested() { throw MediaStopped() }
            let passages = zip(step.frames, frameVectors).map {
                IndexStore.StepPassage(source: "frame", start: $0.second, end: $0.second, modality: "image", text: "", vector: $1)
            } + zip(step.windows, windowVectors).map {
                IndexStore.StepPassage(source: "audio", start: $0.start, end: $0.end, modality: "audio", text: "", vector: $1)
            }
            let stored = try store?.commitStep(
                file, nameWords: step.nameWords, first: file.readTo == nil, passages: passages, readTo: step.readTo,
                total: Int(step.duration.rounded(.up)))
            if stored == true {
                failedInARow.removeAll()
                logUnit(passages.count)
                send(.changed)
            } else {
                skipped.insert(file.id)
            }
        } catch let error as VideoReadError {
            switch error {
            case .unreadable: giveUp(on: file, skipped: &skipped)
            case .cannotOpen: needPermission(file, skipped: &skipped)
            case .changed, .notAdmitted: skipped.insert(file.id)
            }
        } catch is PictureRefused {
            giveUp(on: file, skipped: &skipped)
        } catch is MediaStopped, is MarkerNotWritten, is ModelUnavailable {
            skipped.insert(file.id)
        } catch {
            warn("SesameHelper index: could not embed or store a video step: \(error)")
            modelStepFailed(file, skipped: &skipped)
        }
    }

    /// The vectors of a video step through the real models: its frames in the picture model, then its windows in the audio
    /// model (`embedMedia`). The file is marked and watched while a model embeds, and not while one loads or is swapped out.
    private mutating func mediaVectors(
        _ file: IndexStore.PendingPhoto, _ step: VideoStep, _ batcher: inout Batcher, skipped: inout Set<Int64>
    ) throws -> (images: [[Float]], windows: [[Float]]) {
        guard !step.frames.isEmpty || !step.windows.isEmpty else { return ([], []) }
        if batcher.loaded != (step.frames.isEmpty ? .audio : .image) { settle(.modelLoad) }
        let swapped = !step.frames.isEmpty && !step.windows.isEmpty
        do {
            return try batcher.embedMedia(
                images: step.frames.map(\.bitmap), windows: step.windows.map(\.samples),
                embedImages: { bitmaps in
                    guard enter([file], .embed([0]), skipped: &skipped) else { throw MarkerNotWritten() }
                    defer { if swapped { settle(.modelLoad) } }
                    return try pictureVectors(bitmaps)
                },
                embedWindows: { clips in
                    guard enter([file], .embed([0]), skipped: &skipped) else { throw MarkerNotWritten() }
                    return try windowVectors(clips)
                })
        } catch let error where batcher.loaded == nil && !(error is MarkerNotWritten) && !(error is PictureRefused) && !(error is MediaStopped) {
            warn("SesameHelper index: the model failed: \(error)")
            modelFailed = true
            throw ModelUnavailable()
        }
    }

    /// True once stdin has ended: a step in flight is dropped, uncommitted, and the next run reads it again. Lines still
    /// waiting on stdin stay for `pollInput`.
    private mutating func stopRequested() -> Bool {
        input.hasEnded()
    }

    /// False when the file is there and `Rules` no longer admits it under the current folders. A file that is gone is left
    /// to the reader, which says so.
    private func rulesStillAdmit(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        return Rules.admit(path: Walker.realPath(path), picks: picks) != nil
    }

    /// The one place that decides what is marked and watched. For `step` of `unit` the files in flight (`filesInFlight`)
    /// get the attempt marker and are the watchdog's watch; a marker on any other file is put back. A death now leaves
    /// a marker only on the files in flight. False, with the files left for the next run, when a marker cannot be written.
    private mutating func enter(_ unit: [IndexStore.PendingPhoto], _ step: UnitStep, skipped: inout Set<Int64>) -> Bool {
        let flying = filesInFlight(unit, at: step)
        let flyingIDs = Set(flying.map(\.id))
        let markedIDs = Set(marked.map(\.id))
        putBack(marked.filter { !flyingIDs.contains($0.id) })
        guard markAttempt(flying.filter { !markedIDs.contains($0.id) }, skipped: &skipped) else {
            marked = marked.filter { flyingIDs.contains($0.id) }
            watchdog?.watch(marked)
            return false
        }
        marked = flying
        watchdog?.watch(flying)
        return true
    }

    /// A step with no file in flight (a preview, a stop, the gap after an embed call): every marker goes back and the
    /// watch is cleared.
    private mutating func settle(_ step: UnitStep) {
        var unused = Set<Int64>()
        _ = enter([], step, skipped: &unused)
    }

    /// Adds one try to each file before it is read. False (the files are left for the next run) when it cannot be written.
    private func markAttempt(_ files: [IndexStore.PendingPhoto], skipped: inout Set<Int64>) -> Bool {
        do { try store?.beginAttempt(files) } catch {
            warn("SesameHelper index: could not mark the attempt: \(error)")
            for file in files { skipped.insert(file.id) }
            return false
        }
        return true
    }

    /// Takes the try back from the files that were not written (skipped, deferred, changed under the read).
    private func putBack(_ files: [IndexStore.PendingPhoto]) {
        do { try store?.endAttempt(files) } catch {
            warn("SesameHelper index: could not put the attempt marker back: \(error)")
        }
    }

    /// One typed line per embed unit, `unit n=<inputs>`, through `Log`.
    private func logUnit(_ inputs: Int) {
        guard inputs > 0 else { return }
        do { try Log.write(.unit(inputs: inputs), to: .index) } catch {
            warn("SesameHelper index: could not write index.log")
        }
    }

    /// Commits each file of a unit, one transaction a file, saying `changed` after each commit.
    private mutating func commit(
        _ read: [(file: IndexStore.PendingPhoto, pieces: PhotoPieces)], _ made: [[Float]?], skipped: inout Set<Int64>
    ) {
        guard let store else { return }
        for (item, vector) in zip(read, made) {
            guard let vector else {
                giveUp(on: item.file, skipped: &skipped)
                continue
            }
            do {
                if try store.completePhoto(item.file, nameWords: item.pieces.nameWords, ocrText: item.pieces.ocrText, vector: vector) {
                    send(.changed)
                } else {
                    skipped.insert(item.file.id)
                }
            } catch {
                warn("SesameHelper index: could not store a photo: \(error)")
                skipped.insert(item.file.id)
            }
        }
    }

    /// A photo no decoder takes: `could_not_read`, so it is not read again.
    private mutating func giveUp(on file: IndexStore.PendingPhoto, reason: String = "damaged", skipped: inout Set<Int64>) {
        guard let store else { return }
        do {
            if try store.markCouldNotRead(file, reason: reason) { send(.changed) } else { skipped.insert(file.id) }
        } catch {
            warn("SesameHelper index: could not mark a photo as unreadable: \(error)")
            skipped.insert(file.id)
        }
    }

    /// A photo the process may not open: `needs_permission`, so the panel reads it from the index and it is not read
    /// again in this run. The next helper run tries it again; a changed file is reset by the reconcile.
    private mutating func needPermission(_ file: IndexStore.PendingPhoto, skipped: inout Set<Int64>) {
        guard let store else { return }
        do {
            if try store.markNeedsPermission(file) { send(.changed) } else { skipped.insert(file.id) }
        } catch {
            warn("SesameHelper index: could not mark a photo as needing permission: \(error)")
            skipped.insert(file.id)
        }
    }

    /// Between units: stdin ended ends the run after this unit; a newer `folders` line is applied and the queue is
    /// read again; `panel` changes the unit size; `reset` cancels the batch.
    private mutating func pollInput() {
        // Nothing is marked or watched while input is handled: a preview's memory or a long reconcile is not the unit's.
        settle(.stopping)
        while let next = input.ready() {
            switch next {
            case .end, .idle:
                ending = true
                return
            case let .line(text):
                guard let command = try? HelperProtocol.command(from: text) else { continue }
                switch command {
                case let .folders(folders):
                    reconcile(folders)
                    requeue = true
                case let .panel(open):
                    setPanel(open: open)
                case .reset:
                    reset()
                case let .preview(ticket, file, passage, query):
                    preview(ticket: ticket, file: file, passage: passage, query: query)
                default:
                    continue
                }
            }
        }
    }

    /// Writes one event to the app. When the pipe is gone (EPIPE, the app was killed or closed it) the helper leaves
    /// through `finish`, which puts every marker back first.
    private mutating func send(_ event: HelperEvent) {
        guard let text = try? HelperProtocol.line(for: event),
              (try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))) != nil else {
            finish()
        }
    }
}

private func warn(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

private func quit(_ message: String) -> Never {
    warn("SesameHelper index: \(message)")
    exit(1)
}

/// Lines from stdin, waiting at most a given time for each.
private struct IndexInput {
    enum Next {
        case line(String)
        case idle
        case end
    }

    private var buffer: [UInt8] = []
    private var ended = false

    /// A line or the end of stdin if one is there now, else nil; never waits.
    mutating func ready() -> Next? {
        let result = next(idleSeconds: 0)
        if case .idle = result { return nil }
        return result
    }

    /// True once stdin has ended. Takes in what is waiting without waiting and consumes no line: the lines stay in the buffer.
    mutating func hasEnded() -> Bool {
        while !ended, take(waitingUpTo: 0) {}
        return ended
    }

    /// True when a `preview` line is already waiting behind the command being served: the newer selection.
    mutating func newerPreviewQueued() -> Bool {
        while !ended, take(waitingUpTo: 0) {}
        return buffer.split(separator: 0x0A).contains { line in
            if case .preview? = try? HelperProtocol.command(from: String(decoding: line, as: UTF8.self)) { return true }
            return false
        }
    }

    mutating func next(idleSeconds: Double) -> Next {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(idleSeconds * 1_000_000_000)
        var looked = false
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let text = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return .line(text)
            }
            if ended {
                guard !buffer.isEmpty else { return .end }
                defer { buffer.removeAll() }
                return .line(String(decoding: buffer, as: UTF8.self))
            }
            let now = DispatchTime.now().uptimeNanoseconds
            // One look at stdin even when no time is left, so a poll sees what is already there.
            guard now < deadline || !looked else { return .idle }
            looked = true
            let wait = now < deadline ? min((deadline - now) / 1_000_000 + 1, 1000) : 0
            _ = take(waitingUpTo: Int32(wait))
        }
    }

    /// Waits up to `milliseconds` for stdin and appends what it holds to the buffer. True when bytes came in.
    private mutating func take(waitingUpTo milliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, milliseconds)
        if ready < 0, errno != EINTR {
            ended = true
            return false
        }
        guard ready > 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk[..<count])
            return true
        }
        if count == 0 || errno != EINTR { ended = true }
        return false
    }
}
