import AppKit
import Carbon.HIToolbox

/// Puts one global shortcut in force. `register` is true when the combination is in force; a combination that could not
/// be registered leaves nothing of that call behind. `unregister` takes away what this registrar registered.
@MainActor
protocol HotKeyRegistrar: AnyObject {
    func register(_ combination: String) -> Bool
    func unregister()
}

/// Carbon calls this on the main thread when the registered shortcut is pressed.
private let hotKeyHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { registrar.onPressed?() }
    return noErr
}

/// The app's registrar: Carbon `RegisterEventHotKey`, which needs no permission. The Carbon event handler is installed
/// once, on the first registration, and the one registration in force is released before another is made.
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    /// Called when the registered shortcut is pressed.
    var onPressed: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    init() {}

    func register(_ combination: String) -> Bool {
        guard let key = HotKey.parse(combination) else { return false }
        installHandlerOnce()
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5345_5341), id: 1)  // 'SESA'
        var fresh: EventHotKeyRef?
        let registered = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &fresh)
        guard registered == noErr, let fresh else {
            FileHandle.standardError.write(
                Data("Sesame: could not register the shortcut \(combination) (\(registered))\n".utf8))
            return false
        }
        hotKeyRef = fresh
        return true
    }

    func unregister() {
        guard let old = hotKeyRef else { return }
        hotKeyRef = nil
        let released = UnregisterEventHotKey(old)
        if released != noErr {
            FileHandle.standardError.write(Data("Sesame: could not release the old shortcut (\(released))\n".utf8))
        }
    }

    private func installHandlerOnce() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        if installed == noErr {
            handlerInstalled = true
        } else {
            FileHandle.standardError.write(Data("Sesame: could not install the shortcut handler (\(installed))\n".utf8))
        }
    }
}
