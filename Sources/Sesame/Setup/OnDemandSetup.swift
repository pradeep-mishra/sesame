/// The setup window, built the first time something asks for it. A launch that shows no setup never builds it, so no
/// folder is counted and `~/Developer` is not walked (spec S8: only picked folders are looked at).
@MainActor
final class OnDemandSetup {
    private let make: @MainActor () -> SetupWindow
    private let show: @MainActor (SetupWindow) -> Void
    private(set) var made: SetupWindow?

    /// `show` brings a window to the front; only `downloadFailed` calls it (the launch shows its window its own way).
    init(make: @escaping @MainActor () -> SetupWindow, show: @escaping @MainActor (SetupWindow) -> Void = { _ in }) {
        self.make = make
        self.show = show
    }

    /// The window; the first call builds it.
    func window() -> SetupWindow {
        if let made { return made }
        let window = make()
        made = window
        return window
    }

    /// Reads the model files again for a window that exists. Never builds one.
    func refreshModelIfMade() {
        made?.model.refresh()
    }

    /// The model download gave up: the window (built now when it was never built, reused when it was closed) says so,
    /// offers Retry, and is shown, wherever the person is.
    func downloadFailed(_ text: String) {
        let target = window()
        target.model.downloadFailed(text)
        target.refresh()
        show(target)
    }
}
