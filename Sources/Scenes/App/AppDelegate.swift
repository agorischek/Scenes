import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let closePopoverNotification = Notification.Name("ScenesClosePopover")

    private let environment = SceneEnvironment.shared
    private let statusItemController = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        environment.bootstrap()
        statusItemController.install(
            rootView: SceneMenuView()
                .environmentObject(environment.store)
                .environmentObject(environment.runner),
            target: self,
            action: #selector(togglePopover(_:))
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover(_:)),
            name: Self.closePopoverNotification,
            object: nil
        )
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "scene" {
            if let scene = environment.store.importScene(at: url) {
                environment.runner.run(scene: scene)
            }
        }
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        statusItemController.togglePopover(sender: sender)
    }

    @objc
    private func closePopover(_ notification: Notification) {
        statusItemController.closePopover()
    }
}
