import Foundation

struct SceneDefinition: Identifiable, Codable, Hashable {
    var id: String { url?.path ?? name }

    let name: String
    let steps: [SceneStep]
    var url: URL?

    enum CodingKeys: String, CodingKey {
        case name
        case steps
    }
}

struct SceneStep: Codable, Hashable {
    let type: SceneStepType
    let applicationName: String?
    let bundleIdentifier: String?
    let command: String?
    let url: String?
    let text: String?
    let key: String?
    let seconds: Double?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let xFraction: Double?
    let yFraction: Double?
    let widthFraction: Double?
    let heightFraction: Double?
}

enum SceneStepType: String, Codable, Hashable {
    case launchApp
    case runTerminalCommand
    case openURL
    case runShellCommand
    case delay
    case moveWindow
    case moveFrontmostWindow
    case typeText
    case pressKey
}
