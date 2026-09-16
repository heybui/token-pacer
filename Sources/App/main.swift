import AppKit

if CommandLine.arguments.contains("--probe") {
    await Probe.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // LSUIElement at runtime: no Dock icon, no menu bar
app.run()
