import AppKit
import ApplicationServices
import Combine
import Foundation

enum SceneExecutionState: Equatable {
    case idle
    case running
    case succeeded
    case failed
}

@MainActor
final class SceneRunner: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var currentSceneName: String?
    @Published private(set) var currentStepLabel: String?
    @Published private(set) var currentStepIndex = 0
    @Published private(set) var totalSteps = 0
    @Published private(set) var executionState: SceneExecutionState = .idle
    private var hasRequestedAccessibilityPrompt = false
    private var runToken = UUID()

    func run(scene: SceneDefinition) {
        guard !isRunning else { return }

        let runToken = UUID()
        self.runToken = runToken
        isRunning = true
        executionState = .running
        currentSceneName = scene.name
        totalSteps = scene.steps.count
        currentStepIndex = 0
        currentStepLabel = totalSteps > 0 ? "Preparing scene" : "No steps"
        statusMessage = "Running \(scene.name)..."

        Task {
            do {
                try await execute(scene: scene, runToken: runToken)
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Finished \(scene.name)"
                    self.isRunning = false
                    self.executionState = .succeeded
                    self.currentStepIndex = self.totalSteps
                    self.currentStepLabel = "Complete"
                }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    guard self.runToken == runToken, !self.isRunning, self.executionState == .succeeded else { return }
                    self.resetExecutionDetails()
                }
            } catch {
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Failed: \(error.localizedDescription)"
                    self.isRunning = false
                    self.executionState = .failed
                    self.currentStepLabel = error.localizedDescription
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

    private func execute(scene: SceneDefinition, runToken: UUID) async throws {
        for (index, step) in scene.steps.enumerated() {
            await MainActor.run {
                guard self.runToken == runToken else { return }
                self.currentStepIndex = index + 1
                self.currentStepLabel = self.description(for: step)
                self.statusMessage = "Step \(index + 1) of \(scene.steps.count): \(self.currentStepLabel ?? "")"
            }

            try await execute(step: step)
        }
    }

    private func execute(step: SceneStep) async throws {
        switch step.type {
        case .launchApp:
            try launchApp(named: step.applicationName, bundleIdentifier: step.bundleIdentifier)
        case .launchIOSSimulatorApp:
            try launchIOSSimulatorApp(step: step)
        case .runTerminalCommand:
            try runTerminalCommand(step.command)
        case .runGhosttyCommand:
            try runGhosttyCommand(step.command)
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

    private func runGhosttyCommand(_ command: String?) throws {
        guard let command, !command.isEmpty else {
            throw SceneRunnerError.invalidStep("runGhosttyCommand requires command")
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-na", "/Applications/Ghostty.app", "--args", "-e", "zsh", "-lc", command]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SceneRunnerError.commandFailed("open -na /Applications/Ghostty.app --args -e zsh -lc \(command)", process.terminationStatus)
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

    private func launchIOSSimulatorApp(step: SceneStep) throws {
        let deviceName = step.device ?? "iPhone 17"
        let showSimulator = step.showSimulator ?? true
        let buildStrategy = step.buildStrategy ?? .alwaysBuild

        if showSimulator {
            let openProcess = Process()
            openProcess.executableURL = URL(filePath: "/usr/bin/open")
            openProcess.arguments = ["-a", "Simulator"]
            try openProcess.run()
            openProcess.waitUntilExit()
        }

        let udid = try resolveSimulatorUDID(named: deviceName)
        try bootSimulator(udid: udid)

        var appPath = step.appPath
        var bundleIdentifier = step.bundleIdentifier

        if let projectPath = step.projectPath, !projectPath.isEmpty {
            let scheme = step.scheme ?? "acp-remote"
            let configuration = step.configuration ?? "Debug"
            let destination = step.destination ?? "generic/platform=iOS Simulator"

            var artifact = try resolveIOSBuildArtifact(
                projectPath: projectPath,
                scheme: scheme,
                configuration: configuration,
                destination: destination
            )

            let shouldBuild: Bool
            switch buildStrategy {
            case .alwaysBuild:
                shouldBuild = true
            case .useExistingBuildIfPresent:
                shouldBuild = !FileManager.default.fileExists(atPath: artifact.appPath)
            }

            if shouldBuild {
                try buildIOSProject(
                    projectPath: projectPath,
                    scheme: scheme,
                    configuration: configuration,
                    destination: destination
                )

                artifact = try resolveIOSBuildArtifact(
                    projectPath: projectPath,
                    scheme: scheme,
                    configuration: configuration,
                    destination: destination
                )
            }

            appPath = artifact.appPath
            if bundleIdentifier == nil {
                bundleIdentifier = artifact.bundleIdentifier
            }
        }

        if let appPath, !appPath.isEmpty {
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                try? runCapturedCommand(
                    executable: "/usr/bin/xcrun",
                    arguments: ["simctl", "terminate", udid, bundleIdentifier]
                )
                try? runCapturedCommand(
                    executable: "/usr/bin/xcrun",
                    arguments: ["simctl", "uninstall", udid, bundleIdentifier]
                )
            }

            _ = try runCapturedCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "install", udid, appPath]
            )
        }

        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw SceneRunnerError.invalidStep("launchIOSSimulatorApp requires bundleIdentifier, or projectPath plus scheme that resolves one")
        }

        _ = try runCapturedCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "launch", udid, bundleIdentifier] + (step.arguments ?? [])
        )
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

    private func resolveSimulatorUDID(named deviceName: String) throws -> String {
        let result = try runCapturedCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "--json"]
        )

        guard
            let data = result.stdout.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = payload["devices"] as? [String: Any]
        else {
            throw SceneRunnerError.invalidSimulatorResponse
        }

        for (runtime, entries) in devices {
            guard runtime.contains("iOS"), let entries = entries as? [[String: Any]] else { continue }
            for entry in entries {
                guard let name = entry["name"] as? String, name == deviceName else { continue }
                if let isAvailable = entry["isAvailable"] as? Bool, isAvailable == false {
                    continue
                }
                if let udid = entry["udid"] as? String, !udid.isEmpty {
                    return udid
                }
            }
        }

        throw SceneRunnerError.simulatorDeviceNotFound(deviceName)
    }

    private func bootSimulator(udid: String) throws {
        do {
            _ = try runCapturedCommand(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "boot", udid]
            )
        } catch let error as SceneRunnerError {
            switch error {
            case let .commandFailed(message, _):
                guard message.contains("Unable to boot device in current state: Booted") else {
                    throw error
                }
            default:
                throw error
            }
        }

        _ = try runCapturedCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "bootstatus", udid, "-b"]
        )
    }

    private func buildIOSProject(projectPath: String, scheme: String, configuration: String, destination: String) throws {
        _ = try runCapturedCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", destination,
                "build",
            ],
            currentDirectoryPath: URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        )
    }

    private func resolveIOSBuildArtifact(projectPath: String, scheme: String, configuration: String, destination: String) throws -> IOSBuildArtifact {
        let result = try runCapturedCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", destination,
                "-showBuildSettings",
                "-json",
            ],
            currentDirectoryPath: URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        )

        guard let data = result.stdout.data(using: .utf8) else {
            throw SceneRunnerError.invalidBuildSettings
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SceneRunnerError.invalidBuildSettings
        }

        for entry in payload {
            guard let settings = entry["buildSettings"] as? [String: Any] else { continue }
            guard
                let targetBuildDir = settings["TARGET_BUILD_DIR"] as? String,
                let fullProductName = settings["FULL_PRODUCT_NAME"] as? String,
                fullProductName.hasSuffix(".app")
            else {
                continue
            }

            let appPath = URL(fileURLWithPath: targetBuildDir).appendingPathComponent(fullProductName).path
            let bundleIdentifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            return IOSBuildArtifact(appPath: appPath, bundleIdentifier: bundleIdentifier)
        }

        throw SceneRunnerError.buildArtifactNotFound
    }

    private func runCapturedCommand(
        executable: String,
        arguments: [String],
        currentDirectoryPath: String? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = [stdout, stderr]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let command = ([executable] + arguments).joined(separator: " ")
            let message = detail.isEmpty ? command : "\(command)\n\(detail)"
            throw SceneRunnerError.commandFailed(message, process.terminationStatus)
        }

        return CommandResult(stdout: stdout, stderr: stderr)
    }

    private func description(for step: SceneStep) -> String {
        switch step.type {
        case .launchApp:
            return "Opening \(step.applicationName ?? step.bundleIdentifier ?? "app")"
        case .launchIOSSimulatorApp:
            return "Launching \(step.scheme ?? step.bundleIdentifier ?? "iOS app") on \(step.device ?? "Simulator")"
        case .runTerminalCommand:
            return "Running Terminal command"
        case .runGhosttyCommand:
            return "Running Ghostty command"
        case .openURL:
            return "Opening \(step.url ?? "URL")"
        case .runShellCommand:
            return "Running shell command"
        case .delay:
            return "Waiting \(formattedSeconds(step.seconds ?? 1.0))"
        case .moveWindow:
            return "Positioning \(step.applicationName ?? step.bundleIdentifier ?? "window")"
        case .moveFrontmostWindow:
            return "Positioning frontmost window"
        case .typeText:
            return "Sending text input"
        case .pressKey:
            return "Pressing \(step.key ?? "return")"
        }
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        if seconds.rounded(.towardZero) == seconds {
            return "\(Int(seconds))s"
        }
        return String(format: "%.1fs", seconds)
    }

    private func resetExecutionDetails() {
        currentSceneName = nil
        currentStepLabel = nil
        currentStepIndex = 0
        totalSteps = 0
        executionState = .idle
        statusMessage = "Idle"
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
        let topInset = screen.frame.maxY - visibleFrame.maxY

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
                y: topInset + (visibleFrame.height * yFraction)
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

private struct IOSBuildArtifact {
    let appPath: String
    let bundleIdentifier: String?
}

private struct CommandResult {
    let stdout: String
    let stderr: String
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
    case invalidSimulatorResponse
    case simulatorDeviceNotFound(String)
    case invalidBuildSettings
    case buildArtifactNotFound

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
        case .invalidSimulatorResponse:
            return "Could not read the iOS Simulator device list."
        case let .simulatorDeviceNotFound(device):
            return "Could not find an available iOS simulator named \(device)."
        case .invalidBuildSettings:
            return "Could not parse Xcode build settings for the iOS app."
        case .buildArtifactNotFound:
            return "Could not determine the built iOS app artifact."
        }
    }
}
