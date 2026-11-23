import AcpmRuntimeCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let viewModel = RuntimeViewModel()
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = viewModel.appearance.nsAppearance

        let controller = StatusBarController(viewModel: viewModel)
        self.statusBarController = controller
        viewModel.startMonitoring()

        if !viewModel.hasCompletedOnboarding {
            controller.showConsoleWindow(tab: .overview, openOnboarding: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        statusBarController?.confirmAndQuitIfNeeded() ?? .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            statusBarController?.showConsoleWindow()
        }
        return true
    }
}
