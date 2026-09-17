import AppKit

if CommandLine.arguments.contains("--probe") {
    await Probe.run()
    exit(0)
}

// One pill in the notch, always. A second copy would draw over the first.
guard SingleInstance.acquire() else {
    FileHandle.standardError.write(Data("Burn Tracker is already running.\n".utf8))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // LSUIElement at runtime: no Dock icon, no menu bar
app.run()
