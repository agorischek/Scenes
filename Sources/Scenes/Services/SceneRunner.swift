import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class SceneRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Idle"
    private var hasRequestedAccessibilityPrompt = false

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

    func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityIfNeeded() {
        guard !hasAccessibilityAccess() else { return }

        if !hasRequestedAccessibilityPrompt {
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            hasRequestedAccessibilityPrompt = true
        }

        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
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
        case .runTerminalCommand:
            try runTerminalCommand(step.command)
        case .openURL:
            try openURL(step.url)
        case .runShellCommand:
            try runShellCommand(step.command)
        case .delay:
            try await delay(seconds: step.seconds)
        case .moveWindow:
            try moveWindow(step: step)
        case .moveFrontmostWindow:
            try moveFrontmostWindow(step: step)
        case .typeText:
            try await typeText(step: step)
        case .pressKey:
            try await pressKey(step: step)
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

    private func runTerminalCommand(_ command: String?) throws {
        guard let command, !command.isEmpty else {
            throw SceneRunnerError.invalidStep("runTerminalCommand requires command")
        }

        let scriptsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenesTerminalCommands", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)

        let scriptURL = scriptsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("command")

        let scriptContents = """
        #!/bin/zsh
        \(command)
        """

        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", scriptURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SceneRunnerError.commandFailed("open -a Terminal \(scriptURL.path)", process.terminationStatus)
        }
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

    private func typeText(step: SceneStep) async throws {
        guard hasAccessibilityAccess() else {
            throw SceneRunnerError.accessibilityPermissionRequired
        }

        try await focusAppForInput(using: step)

        let text = step.text
        guard let text, !text.isEmpty else {
            throw SceneRunnerError.invalidStep("typeText requires text")
        }

        for scalar in text.unicodeScalars {
            try postTextEvent(String(scalar))
        }
    }

    private func pressKey(step: SceneStep) async throws {
        guard hasAccessibilityAccess() else {
            throw SceneRunnerError.accessibilityPermissionRequired
        }

        try await focusAppForInput(using: step)

        let normalizedKey = (step.key ?? "return").lowercased()
        switch normalizedKey {
        case "return", "enter":
            try postKeyCode(36)
        case "tab":
            try postKeyCode(48)
        case "space":
            try postKeyCode(49)
        case "escape", "esc":
            try postKeyCode(53)
        default:
            throw SceneRunnerError.invalidStep("Unsupported key: \(normalizedKey)")
        }
    }

    private func moveWindow(step: SceneStep) throws {
        guard hasAccessibilityAccess() else {
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

        let geometry = geometry(for: step)
        try applyGeometry(geometry, to: window)
        app.activate()
    }

    private func moveFrontmostWindow(step: SceneStep) throws {
        guard hasAccessibilityAccess() else {
            throw SceneRunnerError.accessibilityPermissionRequired
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SceneRunnerError.appNotRunning("frontmost application")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows = try copyWindows(for: appElement)
        guard let window = windows.first else {
            throw SceneRunnerError.windowNotFound(app.localizedName ?? "frontmost application")
        }

        let geometry = geometry(for: step)
        try applyGeometry(geometry, to: window)
        app.activate()
    }

    private func applyGeometry(_ geometry: WindowGeometry, to window: AXUIElement) throws {
        var mutablePosition = geometry.position
        var mutableSize = geometry.size
        let positionValue = AXValueCreate(.cgPoint, &mutablePosition)
        let sizeValue = AXValueCreate(.cgSize, &mutableSize)

        guard let positionValue, let sizeValue else {
            throw SceneRunnerError.invalidStep("Could not encode window geometry")
        }

        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    private func postTextEvent(_ text: String) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw SceneRunnerError.inputSynthesisFailed
        }

        down.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
        up.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16))
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postKeyCode(_ keyCode: CGKeyCode) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw SceneRunnerError.inputSynthesisFailed
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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

    private func focusAppForInput(using step: SceneStep) async throws {
        if let app = findRunningApp(applicationName: step.applicationName, bundleIdentifier: step.bundleIdentifier) {
            app.activate()
            try await Task.sleep(for: .milliseconds(250))
            return
        }

        try await Task.sleep(for: .milliseconds(100))
    }

    private func geometry(for step: SceneStep) -> WindowGeometry {
        let fallback = WindowGeometry(
            position: CGPoint(x: step.x ?? 40, y: step.y ?? 40),
            size: CGSize(width: step.width ?? 900, height: step.height ?? 700)
        )

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return fallback
        }

        let visibleFrame = screen.visibleFrame

        guard
            let xFraction = step.xFraction,
            let yFraction = step.yFraction,
            let widthFraction = step.widthFraction,
            let heightFraction = step.heightFraction
        else {
            return fallback
        }

        return WindowGeometry(
            position: CGPoint(
                x: visibleFrame.minX + (visibleFrame.width * xFraction),
                y: visibleFrame.minY + (visibleFrame.height * yFraction)
            ),
            size: CGSize(
                width: visibleFrame.width * widthFraction,
                height: visibleFrame.height * heightFraction
            )
        )
    }
}

private struct WindowGeometry {
    let position: CGPoint
    let size: CGSize
}

enum SceneRunnerError: LocalizedError {
    case invalidStep(String)
    case appNotFound(String)
    case appNotRunning(String)
    case commandFailed(String, Int32)
    case accessibilityPermissionRequired
    case windowNotFound(String)
    case windowEnumerationFailed
    case inputSynthesisFailed

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
            return "Accessibility permission is required to move windows. Use Accessibility Settings from the Scenes menu, then relaunch Scenes if needed."
        case let .windowNotFound(app):
            return "No movable window found for \(app)."
        case .windowEnumerationFailed:
            return "Could not read app windows through Accessibility."
        case .inputSynthesisFailed:
            return "Could not synthesize keyboard input."
        }
    }
}
