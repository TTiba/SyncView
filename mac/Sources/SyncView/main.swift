import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") {
    SelfTest.start()
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
