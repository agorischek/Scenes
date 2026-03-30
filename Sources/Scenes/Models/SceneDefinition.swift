import Foundation

struct SceneDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: String { url?.path ?? name }

    let name: String
    let steps: [SceneStep]
    var url: URL?

    enum CodingKeys: String, CodingKey {
        case name
        case steps
    }
}

struct SceneStep: Codable, Hashable, Sendable {
    let type: SceneStepType
    let applicationName: String?
    let bundleIdentifier: String?
    let command: String?
    let arguments: [String]?
    let buildStrategy: IOSBuildStrategy?
    let buildSettingOverrides: [String]?
    let url: String?
    let text: String?
    let key: String?
    let seconds: Double?
    let projectPath: String?
    let scheme: String?
    let device: String?
    let destination: String?
    let configuration: String?
    let appPath: String?
    let showSimulator: Bool?
    let studioURL: String?
    let authMode: IOSAuthMode?
    let disabledAuthUserId: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let xFraction: Double?
    let yFraction: Double?
    let widthFraction: Double?
    let heightFraction: Double?
}

enum IOSBuildStrategy: String, Codable, Hashable, Sendable {
    case alwaysBuild
    case useExistingBuildIfPresent
}

enum IOSAuthMode: String, Codable, Hashable, Sendable {
    case enabled
    case disabled
}

enum SceneStepType: String, Codable, Hashable, Sendable {
    case launchApp
    case launchIOSSimulatorApp
    case runTerminalCommand
    case runGhosttyCommand
    case openURL
    case runShellCommand
    case delay
    case moveWindow
    case moveFrontmostWindow
    case typeText
    case pressKey
}
