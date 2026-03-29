import Foundation

@MainActor
final class SceneEnvironment {
    static let shared = SceneEnvironment()

    let store = SceneStore()
    let runner = SceneRunner()

    private init() {}

    func bootstrap() {
        store.refresh()
    }
}
