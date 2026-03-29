import SwiftUI

@main
struct ScenesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SceneStore
    @StateObject private var runner: SceneRunner

    init() {
        _store = StateObject(wrappedValue: SceneEnvironment.shared.store)
        _runner = StateObject(wrappedValue: SceneEnvironment.shared.runner)
    }

    var body: some Scene {
        MenuBarExtra("Scenes", systemImage: "sparkles.rectangle.stack") {
            SceneMenuView()
                .environmentObject(store)
                .environmentObject(runner)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}
