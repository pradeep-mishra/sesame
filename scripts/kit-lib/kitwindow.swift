// The kit's own test window: a window the kit owns, so the driver can be tried (pictures, keys,
// reading, pressing, full screen) without ever touching the person's apps or screen.
//
//   kitwindow [--flat] [--title <text>] [--ttl <seconds>] [--pidfile <path>]
//
// Without --flat: a titled window with a colour gradient, a label, a text field ("Kit field"), a
// button ("Kit button") and a check box ("Kit box"); it can go full screen; the system-wide shortcut
// Control+Option+K hides and shows it, which stands in for the app's own shortcut when the driver is tried.
// With --flat: one borderless window of a single flat colour, which a picture check must call blank.
// The process quits by itself after --ttl seconds (default 900), so a forgotten window never stays.
// scripts/kit-ax.sh `kitwindow open|close|status` starts and stops it and keeps its pid.
import AppKit
import Carbon

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var flat = false
var swatch = false
var windowTitle = "Kit test window"
var ttl = 900.0
var pidFile: String?
let arguments = CommandLine.arguments
var argIndex = 1
while argIndex < arguments.count {
    switch arguments[argIndex] {
    case "--flat":
        flat = true; argIndex += 1
    case "--swatch":
        swatch = true; argIndex += 1
    case "--title":
        guard argIndex + 1 < arguments.count else { fail("usage: kitwindow [--flat] [--title <text>] [--ttl <seconds>]", 2) }
        windowTitle = arguments[argIndex + 1]; argIndex += 2
    case "--ttl":
        guard argIndex + 1 < arguments.count, let n = Double(arguments[argIndex + 1]), n > 0 else {
            fail("usage: kitwindow [--flat] [--title <text>] [--ttl <seconds>] [--pidfile <path>]", 2)
        }
        ttl = n; argIndex += 2
    case "--pidfile":
        guard argIndex + 1 < arguments.count else {
            fail("usage: kitwindow [--flat] [--title <text>] [--ttl <seconds>] [--pidfile <path>]", 2)
        }
        pidFile = arguments[argIndex + 1]; argIndex += 2
    default:
        fail("usage: kitwindow [--flat] [--title <text>] [--ttl <seconds>] [--pidfile <path>]", 2)
    }
}
// Launch Services starts the bundle and gives no pid back, so the process writes its own.
if let path = pidFile {
    try? "\(getpid())\n".write(toFile: path, atomically: true, encoding: .utf8)
}

final class KitView: NSView {
    let isFlat: Bool
    init(frame: NSRect, flat: Bool) {
        isFlat = flat
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draw(_ dirtyRect: NSRect) {
        if isFlat {
            NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
            bounds.fill()
        } else {
            NSGradient(colors: [.systemBlue, .systemPink, .systemYellow, .systemGreen])?.draw(in: bounds, angle: 35)
        }
    }
}

final class KitController: NSObject {
    let window: NSWindow
    let status = NSTextField(labelWithString: "Kit label")

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    @objc func buttonPressed(_ sender: Any?) { status.stringValue = "Kit button pressed" }
    @objc func boxToggled(_ sender: Any?) { status.stringValue = "Kit box toggled" }

    func toggleVisible() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

let app = NSApplication.shared

// --swatch: the control of `kit-ax.sh shot --panel`. One small borderless window of the known colour #3399CC
// (sRGB). It never takes the front (accessory app, no activation), so the app that was frontmost stays
// frontmost while the kit takes a picture of it; a picture that cannot show this colour was not really taken.
if swatch {
    app.setActivationPolicy(.accessory)
    let swatchSize = NSSize(width: 220, height: 110)
    let swatchWindow = NSWindow(contentRect: NSRect(origin: .zero, size: swatchSize), styleMask: [.borderless],
                                backing: .buffered, defer: false)
    swatchWindow.isReleasedWhenClosed = false
    swatchWindow.hasShadow = false
    swatchWindow.backgroundColor = NSColor(srgbRed: 0x33 / 255.0, green: 0x99 / 255.0, blue: 0xCC / 255.0, alpha: 1)
    swatchWindow.center()
    swatchWindow.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + ttl) { exit(0) }
    app.run()
    exit(0)
}

app.setActivationPolicy(.regular)

// A main menu with Edit, so Command+V, Command+C and Command+A reach the field as they do in any app
// (a bare process has no menu and swallows them), and the person can quit it with Command+Q.
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu(title: "kitwindow")
appMenu.addItem(NSMenuItem(title: "Quit kitwindow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
appMenuItem.submenu = appMenu
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
editMenuItem.submenu = editMenu
app.mainMenu = mainMenu

let size = flat ? NSSize(width: 400, height: 300) : NSSize(width: 480, height: 320)
let style: NSWindow.StyleMask = flat ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable]
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.title = windowTitle
window.collectionBehavior = [.fullScreenPrimary]
let content = KitView(frame: NSRect(origin: .zero, size: size), flat: flat)
window.contentView = content
let controller = KitController(window: window)

if !flat {
    let field = NSTextField(frame: NSRect(x: 30, y: 230, width: 300, height: 24))
    field.placeholderString = "Kit field"
    content.addSubview(field)

    let field2 = NSTextField(frame: NSRect(x: 30, y: 270, width: 300, height: 24))
    field2.placeholderString = "Kit field two"
    content.addSubview(field2)

    let button = NSButton(title: "Kit button", target: controller, action: #selector(KitController.buttonPressed(_:)))
    button.frame = NSRect(x: 30, y: 180, width: 140, height: 32)
    content.addSubview(button)

    let box = NSButton(checkboxWithTitle: "Kit box", target: controller, action: #selector(KitController.boxToggled(_:)))
    box.frame = NSRect(x: 30, y: 140, width: 140, height: 24)
    content.addSubview(box)

    controller.status.frame = NSRect(x: 30, y: 100, width: 300, height: 24)
    content.addSubview(controller.status)
    window.initialFirstResponder = field
    window.autorecalculatesKeyViewLoop = true
}

window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

if !flat {
    // A system-wide shortcut, registered through Carbon the way the product registers its own: Control+
    // Option+K hides or shows the window even while it is hidden. (Control+Option+Space is the product's
    // chord, so the kit window uses a different one.)
    var hotKeyRef: EventHotKeyRef?
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { controller.toggleVisible() }
        return noErr
    }, 1, &pressed, nil, nil)
    RegisterEventHotKey(40, UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4B49_544B), id: 1),
                        GetApplicationEventTarget(), 0, &hotKeyRef)
}

DispatchQueue.main.asyncAfter(deadline: .now() + ttl) { exit(0) }
app.run()
