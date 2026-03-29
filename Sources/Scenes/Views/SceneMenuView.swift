import SwiftUI

struct SceneMenuView: View {
    @EnvironmentObject private var store: SceneStore
    @EnvironmentObject private var runner: SceneRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scenes")
                        .font(.headline)
                    Text(store.scenesDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if store.scenes.isEmpty {
                Text("No .scene files found in ~/Scenes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.scenes) { scene in
                    Button {
                        runner.run(scene: scene)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene.name)
                            if let url = scene.url {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .disabled(runner.isRunning)
                }
            }

            Divider()

            Text(runner.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Refresh") {
                    store.refresh()
                }

                Button("Open Scenes Folder") {
                    NSWorkspace.shared.open(store.scenesDirectory)
                }

                Button("Accessibility") {
                    runner.requestAccessibilityIfNeeded()
                }
            }

            Button("Quit Scenes") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            SceneEnvironment.shared.bootstrap()
        }
    }
}
