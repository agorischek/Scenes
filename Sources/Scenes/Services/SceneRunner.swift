import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class SceneRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Idle"

    func run(scene: SceneDefinition) {
        guard !isRunning else { return }

        isRunning = true
        statusMessage = "Running \(scene.name)..."

        Task {
            do {
                try await execute(scene: scene)
                await MainActor.run {
                    self.statusMessage = "Finished \(scene.name)"
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed: \(error.localizedDescription)"
                    self.isRunning = false
                }
            }
        }
    }

    func requestAccessibilityIfNeeded() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func execute(scene: SceneDefinition) async throws {
        for step in scene.steps {
            try await execute(step: step)
        }
    }

    private func execute(step: SceneStep) async throws {
        switch step.type {
        case .launchApp:
            try launchApp(named: step.applicationName, bundleIdentifier: step.bundleIdentifier)
        case .openURL:
            try openURL(step.url)
        case .runShellCommand:
            try runShellCommand(step.command)
        case .delay:
            try await delay(seconds: step.seconds)
        case .moveWindow:
            try moveWindow(step: step)
        }
    }

    private func launchApp(named applicationName: String?, bundleIdentifier: String?) throws {
        if let bundleIdentifier {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw SceneRunnerError.appNotFound(bundleIdentifier)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }

        guard let applicationName else {
            throw SceneRunnerError.invalidStep("launchApp requires applicationName or bundleIdentifier")
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationName) ??
            NSWorkspace.shared.fullPath(forApplication: applicationName).map({ URL(fileURLWithPath: $0) }) else {
            throw SceneRunnerError.appNotFound(applicationName)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func openURL(_ rawURL: String?) throws {
        guard let rawURL, let url = URL(string: rawURL) else {
            throw SceneRunnerError.invalidStep("openURL requires a valid url")
        }

        NSWorkspace.shared.open(url)
    }

    private func runShellCommand(_ command: String?) throws {
        guard let command, !command.isEmpty else {
            throw SceneRunnerError.invalidStep("runShellCommand requires command")
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", command]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SceneRunnerError.commandFailed(command, process.terminationStatus)
        }
    }

    private func delay(seconds: Double?) async throws {
        let seconds = seconds ?? 1.0
        try await Task.sleep(for: .seconds(seconds))
    }

    private func moveWindow(step: SceneStep) throws {
        requestAccessibilityIfNeeded()

        guard AXIsProcessTrusted() else {
            throw SceneRunnerError.accessibilityPermissionRequired
        }

        guard let app = findRunningApp(applicationName: step.applicationName, bundleIdentifier: step.bundleIdentifier) else {
            throw SceneRunnerError.appNotRunning(step.applicationName ?? step.bundleIdentifier ?? "unknown")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = try copyWindows(for: appElement)
        guard let window = windows.first else {
            throw SceneRunnerError.windowNotFound(app.localizedName ?? "Unknown")
        }

        let position = CGPoint(x: step.x ?? 40, y: step.y ?? 40)
        let size = CGSize(width: step.width ?? 900, height: step.height ?? 700)

        var mutablePosition = position
        var mutableSize = size
        let positionValue = AXValueCreate(.cgPoint, &mutablePosition)
        let sizeValue = AXValueCreate(.cgSize, &mutableSize)

        guard let positionValue, let sizeValue else {
            throw SceneRunnerError.invalidStep("Could not encode window geometry")
        }

        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        NSRunningApplication(processIdentifier: app.processIdentifier)?.activate()
    }

    private func copyWindows(for appElement: AXUIElement) throws -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let array = value as? [AXUIElement] else {
            throw SceneRunnerError.windowEnumerationFailed
        }
        return array
    }

    private func findRunningApp(applicationName: String?, bundleIdentifier: String?) -> NSRunningApplication? {
        if let bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        }

        guard let applicationName else { return nil }

        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == applicationName
        }
    }
}

enum SceneRunnerError: LocalizedError {
    case invalidStep(String)
    case appNotFound(String)
    case appNotRunning(String)
    case commandFailed(String, Int32)
    case accessibilityPermissionRequired
    case windowNotFound(String)
    case windowEnumerationFailed

    var errorDescription: String? {
        switch self {
        case let .invalidStep(message):
            return message
        case let .appNotFound(app):
            return "Could not find app: \(app)"
        case let .appNotRunning(app):
            return "App is not running: \(app)"
        case let .commandFailed(command, status):
            return "Command failed with status \(status): \(command)"
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required to move windows."
        case let .windowNotFound(app):
            return "No movable window found for \(app)."
        case .windowEnumerationFailed:
            return "Could not read app windows through Accessibility."
        }
    }
}
