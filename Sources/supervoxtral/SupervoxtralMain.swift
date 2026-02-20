import AppKit

@MainActor
private var retainedAppDelegate: AppDelegate?

@main
@MainActor
struct SupervoxtralMain {
    static func main() {
        AppLog.write("[supervoxtral] Process start")
        let app = NSApplication.shared
        retainedAppDelegate = AppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = retainedAppDelegate
        app.run()
    }
}
