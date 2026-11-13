import Foundation
import SesameEngine

/// Keeps the measured seconds per file in `settings.json` (`speeds`, design section 1). The bench runs once, when
/// the model is whole and there is no photo speed yet. A failed run is reported once and not repeated in this launch;
/// the next launch asks again.
@MainActor
final class SpeedsStore {
    private let helper: HelperClient
    private let settingsChanged: () -> Void
    private let failed: (Error) -> Void
    private var busy = false
    /// True from the moment a bench is accepted until it has ended (worked or failed). The supervisor holds the index
    /// helper back while it is true.
    private(set) var isMeasuring = false

    init(helper: HelperClient, settingsChanged: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        self.helper = helper
        self.settingsChanged = settingsChanged
        self.failed = failed
    }

    func measureIfNeeded(modelWhole: Bool) {
        guard modelWhole, !busy else { return }
        guard let settings = try? SettingsFile().read(), settings.speeds["photo"] == nil else { return }
        busy = true
        isMeasuring = true
        helper.runBench { [weak self] result in
            Task { @MainActor in self?.finished(result) }
        }
    }

    /// `busy` stays set after a failure or a timeout: no second run in this launch. A bench stopped by Quit is neither: it
    /// writes no line and reports nothing.
    private func finished(_ result: Result<[String: Double], Error>) {
        isMeasuring = false
        switch result {
        case let .failure(error):
            if case .quitting? = error as? BenchError { return }
            fail(error)
        case let .success(speeds):
            do {
                var settings = try SettingsFile().read()
                settings.speeds.merge(speeds) { _, measured in measured }
                try SettingsFile().write(settings)
            } catch {
                fail(error)
                return
            }
            busy = false
            settingsChanged()
        }
    }

    /// One typed line in app.log (no path, no error text), then the caller's report.
    private func fail(_ error: Error) {
        var status = BenchStatus.failed
        if case .timedOut? = error as? BenchError { status = .timeout }
        try? Log.write(.benchStatus(status), to: .app)
        failed(error)
    }
}
