import SwiftUI

struct SceneMenuView: View {
    @EnvironmentObject private var store: SceneStore
    @EnvironmentObject private var runner: SceneRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scenes")
                    .font(.system(size: 16, weight: .semibold))

                Text(store.scenesDirectory.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            if store.scenes.isEmpty {
                Text("No .scene files found in ~/Scenes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.scenes) { scene in
                        MenuActionRow(
                            title: scene.name,
                            systemImage: "play.circle",
                            isEnabled: !runner.isRunning
                        ) {
                            runner.run(scene: scene)
                        }
                    }
                }
            }

            Divider()

            VStack(spacing: 0) {
                MenuActionRow(title: "Refresh", systemImage: "arrow.clockwise") {
                store.refresh()
                }

                MenuActionRow(title: "Open Scenes Folder...", systemImage: "folder") {
                    NSWorkspace.shared.open(store.scenesDirectory)
                }

                MenuActionRow(title: "Accessibility Settings...", systemImage: "hand.raised") {
                    runner.requestAccessibilityIfNeeded()
                }
            }

            if let lastError = store.lastError {
                Divider()
                Text("Error: \(lastError)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Text(runner.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            MenuActionRow(title: "Quit Scenes", systemImage: "xmark.rectangle") {
                    NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 344, alignment: .leading)
        .onAppear {
            SceneEnvironment.shared.bootstrap()
        }
    }
}
