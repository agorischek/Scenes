import Combine
import Foundation

@MainActor
final class SceneStore: ObservableObject {
    @Published private(set) var scenes: [SceneDefinition] = []
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default

    var scenesDirectory: URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Scenes", isDirectory: true)
    }

    func refresh() {
        do {
            try ensureScenesDirectoryExists()
            scenes = try loadDiscoveredScenes()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importScene(at url: URL) -> SceneDefinition? {
        do {
            try ensureScenesDirectoryExists()
            let destination = scenesDirectory.appendingPathComponent(url.lastPathComponent)

            if destination.standardizedFileURL != url.standardizedFileURL {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: url, to: destination)
            }

            refresh()
            return scenes.first { $0.url?.standardizedFileURL == destination.standardizedFileURL }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func ensureScenesDirectoryExists() throws {
        if !fileManager.fileExists(atPath: scenesDirectory.path) {
            try fileManager.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)
        }
    }

    private func loadDiscoveredScenes() throws -> [SceneDefinition] {
        let urls = try fileManager.contentsOfDirectory(
            at: scenesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()

        return try urls
            .filter { $0.pathExtension.lowercased() == "scene" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let data = try Data(contentsOf: url)
                var scene = try decoder.decode(SceneDefinition.self, from: data)
                scene.url = url
                return scene
            }
    }
}
