import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SceneEnvironment.shared.bootstrap()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "scene" {
            if let scene = SceneEnvironment.shared.store.importScene(at: url) {
                SceneEnvironment.shared.runner.run(scene: scene)
            }
        }
    }
}
