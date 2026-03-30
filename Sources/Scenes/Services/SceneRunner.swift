import AppKit
import ApplicationServices
import Combine
import Foundation

private final class SceneProcessRegistry: @unchecked Sendable {
    static let shared = SceneProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        if process.processIdentifier > 0 {
            _ = setpgid(process.processIdentifier, process.processIdentifier)
        }
        lock.lock()
        processes[ObjectIdentifier(process)] = process
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func cancelAll() {
        let activeProcesses: [Process]
        lock.lock()
        activeProcesses = Array(processes.values)
        lock.unlock()

        for process in activeProcesses where process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGTERM)
            } else {
                process.terminate()
            }
        }

        Thread.sleep(forTimeInterval: 0.2)

        for process in activeProcesses where process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGKILL)
            } else {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

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
    @Published private(set) var isOverlayDismissed = false
    @Published private(set) var canTeardown = false
    private var hasRequestedAccessibilityPrompt = false
    private var runToken = UUID()
    private var activeTask: Task<Void, Never>?
    private var cleanupActions: [SceneCleanupAction] = []
    private var lastSceneName: String?

    func run(scene: SceneDefinition) {
        guard !isRunning else { return }

        let runToken = UUID()
        self.runToken = runToken
        cleanupActions = []
        canTeardown = false
        lastSceneName = scene.name
        isRunning = true
        executionState = .running
        isOverlayDismissed = false
        currentSceneName = scene.name
        totalSteps = scene.steps.count
        currentStepIndex = 0
        currentStepLabel = totalSteps > 0 ? "Preparing scene" : "No steps"
        statusMessage = "Running \(scene.name)..."

        activeTask = Task {
            do {
                try await execute(scene: scene, runToken: runToken)
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Finished \(scene.name)"
                    self.isRunning = false
                    self.executionState = .succeeded
                    self.currentStepIndex = self.totalSteps
                    self.currentStepLabel = "Complete"
                    self.activeTask = nil
                }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    guard self.runToken == runToken, !self.isRunning, self.executionState == .succeeded else { return }
                    self.resetExecutionDetails()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Canceled \(scene.name)"
                    self.isRunning = false
                    self.executionState = .failed
                    self.currentStepLabel = "Canceled"
                    self.activeTask = nil
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        guard self.runToken == runToken else { return }
                        self.statusMessage = "Canceled \(scene.name)"
                        self.isRunning = false
                        self.executionState = .failed
                        self.currentStepLabel = "Canceled"
                        self.activeTask = nil
                    }
                    return
                }
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Failed: \(error.localizedDescription)"
                    self.isRunning = false
                    self.executionState = .failed
                    self.currentStepLabel = error.localizedDescription
                    self.activeTask = nil
                }
            }
        }
    }

    func cancelCurrentScene() {
        guard isRunning else { return }
        activeTask?.cancel()
        SceneProcessRegistry.shared.cancelAll()
    }

    func teardownLastScene() {
        guard !isRunning else { return }
        guard !cleanupActions.isEmpty else {
            statusMessage = "Nothing to tear down"
            return
        }

        let runToken = UUID()
        self.runToken = runToken
        let actions = cleanupActions.reversed()
        cleanupActions = []
        canTeardown = false
        isRunning = true
        executionState = .running
        isOverlayDismissed = false
        currentSceneName = lastSceneName.map { "\($0) Teardown" } ?? "Scene Teardown"
        currentStepIndex = 0
        totalSteps = actions.count
        currentStepLabel = actions.isEmpty ? "Nothing to tear down" : "Preparing teardown"
        statusMessage = "Tearing down scene..."

        activeTask = Task {
            do {
                for (index, action) in actions.enumerated() {
                    try Task.checkCancellation()

                    await MainActor.run {
                        guard self.runToken == runToken else { return }
                        self.currentStepIndex = index + 1
                        self.currentStepLabel = self.description(for: action)
                        self.statusMessage = "Teardown step \(index + 1) of \(actions.count): \(self.currentStepLabel ?? "")"
                    }

                    try await performCleanup(action)
                }

                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Teardown complete"
                    self.isRunning = false
                    self.executionState = .succeeded
                    self.currentStepIndex = self.totalSteps
                    self.currentStepLabel = "Complete"
                    self.activeTask = nil
                }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    guard self.runToken == runToken, !self.isRunning, self.executionState == .succeeded else { return }
                    self.resetExecutionDetails()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Teardown canceled"
                    self.isRunning = false
                    self.executionState = .failed
                    self.currentStepLabel = "Canceled"
                    self.activeTask = nil
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        guard self.runToken == runToken else { return }
                        self.statusMessage = "Teardown canceled"
                        self.isRunning = false
                        self.executionState = .failed
                        self.currentStepLabel = "Canceled"
                        self.activeTask = nil
                    }
                    return
                }
                await MainActor.run {
                    guard self.runToken == runToken else { return }
                    self.statusMessage = "Teardown failed: \(error.localizedDescription)"
                    self.isRunning = false
                    self.executionState = .failed
                    self.currentStepLabel = error.localizedDescription
                    self.activeTask = nil
                }
            }
        }
    }

    func dismissOverlay() {
        isOverlayDismissed = true
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
            try Task.checkCancellation()

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
            let resolvedApp = try resolveApplication(named: step.applicationName, bundleIdentifier: step.bundleIdentifier)
            let wasRunning = isAppRunning(bundleIdentifier: resolvedApp.bundleIdentifier)
            try launchApp(resolvedApp)
            if !wasRunning {
                storeCleanup(.terminateApp(bundleIdentifier: resolvedApp.bundleIdentifier))
            }
        case .bootIOSSimulator:
            let simulatorWasRunning = isAppRunning(bundleIdentifier: "com.apple.iphonesimulator")
            let prelaunchState = try await performBlockingStep {
                try Self.resolveSimulatorLaunchState(for: step)
            }
            let result = try await performBlockingStep {
                try Self.bootIOSSimulator(step: step)
            }
            if !prelaunchState.wasBooted {
                storeCleanup(.shutdownSimulator(udid: result.udid))
            }
            if result.didOpenSimulatorApp && !simulatorWasRunning {
                storeCleanup(.terminateApp(bundleIdentifier: "com.apple.iphonesimulator"))
            }
        case .launchIOSSimulatorApp:
            let simulatorWasRunning = isAppRunning(bundleIdentifier: "com.apple.iphonesimulator")
            let prelaunchState = try await performBlockingStep {
                try Self.resolveSimulatorLaunchState(for: step)
            }
            let result = try await performBlockingStep {
                try Self.launchIOSSimulatorApp(step: step)
            }
            storeCleanup(.terminateIOSSimulatorApp(udid: result.udid, bundleIdentifier: result.bundleIdentifier))
            if !prelaunchState.wasBooted {
                storeCleanup(.shutdownSimulator(udid: result.udid))
            }
            if (step.showSimulator ?? true) && !simulatorWasRunning {
                storeCleanup(.terminateApp(bundleIdentifier: "com.apple.iphonesimulator"))
            }
        case .hideAllWindows:
            try hideAllWindows()
        case .runTerminalCommand:
            let wasRunning = isAppRunning(bundleIdentifier: "com.apple.Terminal")
            try await performBlockingStep {
                try Self.runTerminalCommand(step.command)
            }
            if !wasRunning {
                storeCleanup(.terminateApp(bundleIdentifier: "com.apple.Terminal"))
            }
        case .runGhosttyCommand:
            let wasRunning = isAppRunning(bundleIdentifier: "com.mitchellh.ghostty")
            try await performBlockingStep {
                try Self.runGhosttyCommand(step.command)
            }
            if !wasRunning {
                storeCleanup(.terminateApp(bundleIdentifier: "com.mitchellh.ghostty"))
            }
        case .openURL:
            let resolvedOpenURL = try resolvedOpenURL(for: step.url)
            let wasRunning = isAppRunning(bundleIdentifier: resolvedOpenURL.bundleIdentifier)
            try openURL(resolvedOpenURL.url.absoluteString)
            if !wasRunning {
                storeCleanup(.terminateApp(bundleIdentifier: resolvedOpenURL.bundleIdentifier))
            }
        case .runShellCommand:
            let inferredCleanup = Self.inferredCleanupAction(for: step.command)
            try await performBlockingStep {
                try Self.runShellCommand(step.command)
            }
            if let inferredCleanup {
                storeCleanup(inferredCleanup)
            }
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

    private func performCleanup(_ action: SceneCleanupAction) async throws {
        switch action {
        case let .terminateApp(bundleIdentifier):
            terminateRunningApps(bundleIdentifier: bundleIdentifier)
        case let .runShellCommand(command):
            try await performBlockingStep {
                try Self.runShellCommand(command)
            }
        case let .terminateIOSSimulatorApp(udid, bundleIdentifier):
            try await performBlockingStep {
                _ = try Self.runCapturedCommand(
                    executable: "/usr/bin/xcrun",
                    arguments: ["simctl", "terminate", udid, bundleIdentifier]
                )
            }
        case let .shutdownSimulator(udid):
            try await performBlockingStep {
                _ = try Self.runCapturedCommand(
                    executable: "/usr/bin/xcrun",
                    arguments: ["simctl", "shutdown", udid]
                )
            }
        }
    }

    private func performBlockingStep<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func launchApp(_ app: ResolvedApplication) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
    }

    private func openURL(_ rawURL: String?) throws {
        guard let rawURL, let url = URL(string: rawURL) else {
            throw SceneRunnerError.invalidStep("openURL requires a valid url")
        }

        NSWorkspace.shared.open(url)
    }

    private func resolveApplication(named applicationName: String?, bundleIdentifier: String?) throws -> ResolvedApplication {
        if let bundleIdentifier {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw SceneRunnerError.appNotFound(bundleIdentifier)
            }
            return ResolvedApplication(url: url, bundleIdentifier: bundleIdentifier)
        }

        guard let applicationName else {
            throw SceneRunnerError.invalidStep("launchApp requires applicationName or bundleIdentifier")
        }

        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationName) {
            let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier ?? applicationName
            return ResolvedApplication(url: bundleURL, bundleIdentifier: bundleIdentifier)
        }

        guard let appPath = NSWorkspace.shared.fullPath(forApplication: applicationName) else {
            throw SceneRunnerError.appNotFound(applicationName)
        }

        let url = URL(fileURLWithPath: appPath)
        let resolvedBundleIdentifier = Bundle(url: url)?.bundleIdentifier ?? applicationName
        return ResolvedApplication(url: url, bundleIdentifier: resolvedBundleIdentifier)
    }

    private func resolvedOpenURL(for rawURL: String?) throws -> ResolvedOpenURL {
        guard let rawURL, let url = URL(string: rawURL) else {
            throw SceneRunnerError.invalidStep("openURL requires a valid url")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw SceneRunnerError.invalidStep("Could not resolve the default app for \(rawURL)")
        }
        let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier ?? appURL.deletingPathExtension().lastPathComponent
        return ResolvedOpenURL(url: url, bundleIdentifier: bundleIdentifier)
    }

    private func isAppRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    private func terminateRunningApps(bundleIdentifier: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for app in apps {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    private func storeCleanup(_ action: SceneCleanupAction) {
        guard !cleanupActions.contains(action) else { return }
        cleanupActions.append(action)
        canTeardown = !cleanupActions.isEmpty
    }

    nonisolated private static func runTerminalCommand(_ command: String?) throws {
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
        SceneProcessRegistry.shared.register(process)
        defer { SceneProcessRegistry.shared.unregister(process) }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SceneRunnerError.commandFailed("open -a Terminal \(scriptURL.path)", process.terminationStatus)
        }
    }

    nonisolated private static func runGhosttyCommand(_ command: String?) throws {
        guard let command, !command.isEmpty else {
            throw SceneRunnerError.invalidStep("runGhosttyCommand requires command")
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-na", "/Applications/Ghostty.app", "--args", "-e", "zsh", "-lc", command]
        try process.run()
        SceneProcessRegistry.shared.register(process)
        defer { SceneProcessRegistry.shared.unregister(process) }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SceneRunnerError.commandFailed("open -na /Applications/Ghostty.app --args -e zsh -lc \(command)", process.terminationStatus)
        }
    }

    nonisolated private static func runShellCommand(_ command: String?) throws {
        guard let command, !command.isEmpty else {
            throw SceneRunnerError.invalidStep("runShellCommand requires command")
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", command]

        try process.run()
        SceneProcessRegistry.shared.register(process)
        defer { SceneProcessRegistry.shared.unregister(process) }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SceneRunnerError.commandFailed(command, process.terminationStatus)
        }
    }

    nonisolated private static func launchIOSSimulatorApp(step: SceneStep) throws -> IOSSimulatorLaunchResult {
        let buildStrategy = step.buildStrategy ?? .alwaysBuild
        let buildSettingOverrides = try iosBuildSettingOverrides(for: step)
        let launchConfiguration = try iosLaunchConfiguration(for: step)
        let bootResult = try bootIOSSimulator(step: step)
        let udid = bootResult.udid

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
                destination: destination,
                buildSettingOverrides: buildSettingOverrides
            )

            let shouldBuild: Bool
            switch buildStrategy {
            case .alwaysBuild:
                shouldBuild = true
            case .useExistingBuildIfPresent:
                shouldBuild = shouldBuildIOSArtifact(
                    artifact: artifact,
                    launchConfiguration: launchConfiguration,
                    buildSettingOverrides: buildSettingOverrides
                )
            }

            if shouldBuild {
                try buildIOSProject(
                    projectPath: projectPath,
                    scheme: scheme,
                    configuration: configuration,
                    destination: destination,
                    buildSettingOverrides: buildSettingOverrides
                )

                artifact = try resolveIOSBuildArtifact(
                    projectPath: projectPath,
                    scheme: scheme,
                    configuration: configuration,
                    destination: destination,
                    buildSettingOverrides: buildSettingOverrides
                )
            }

            try applyIOSLaunchConfiguration(launchConfiguration, to: artifact)
            try persistIOSLaunchConfiguration(launchConfiguration, for: artifact)

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
            arguments: ["simctl", "launch", udid, bundleIdentifier]
                + launchConfiguration.arguments
                + (step.arguments ?? []),
            environment: launchConfiguration.environment
        )

        return IOSSimulatorLaunchResult(udid: udid, bundleIdentifier: bundleIdentifier)
    }

    nonisolated private static func bootIOSSimulator(step: SceneStep) throws -> BootIOSSimulatorResult {
        let deviceName = step.device ?? "iPhone 17"
        let showSimulator = step.showSimulator ?? true
        let udid = try resolveSimulatorUDID(named: deviceName)

        if showSimulator {
            let openProcess = Process()
            openProcess.executableURL = URL(filePath: "/usr/bin/open")
            openProcess.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
            try openProcess.run()
            SceneProcessRegistry.shared.register(openProcess)
            defer { SceneProcessRegistry.shared.unregister(openProcess) }
            openProcess.waitUntilExit()
        }

        try bootSimulator(udid: udid)
        return BootIOSSimulatorResult(udid: udid, didOpenSimulatorApp: showSimulator)
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

    private func hideAllWindows() throws {
        guard hasAccessibilityAccess() else {
            throw SceneRunnerError.accessibilityPermissionRequired
        }

        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }

        for app in runningApps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let windows = try? copyWindows(for: appElement) {
                for window in windows {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }

            app.hide()
        }
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

    nonisolated private static func resolveSimulatorUDID(named deviceName: String) throws -> String {
        let result = try runCapturedCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "--json"]
        )

        guard
            let data = result.stdout.data(using: String.Encoding.utf8),
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

    nonisolated private static func resolveSimulatorLaunchState(for step: SceneStep) throws -> SimulatorLaunchState {
        let deviceName = step.device ?? "iPhone 17"
        let udid = try resolveSimulatorUDID(named: deviceName)
        let result = try runCapturedCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", udid, "--json"]
        )

        guard
            let data = result.stdout.data(using: .utf8),
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = payload["devices"] as? [String: Any]
        else {
            throw SceneRunnerError.invalidSimulatorResponse
        }

        for (_, entries) in devices {
            guard let entries = entries as? [[String: Any]] else { continue }
            for entry in entries where (entry["udid"] as? String) == udid {
                let state = entry["state"] as? String
                return SimulatorLaunchState(udid: udid, wasBooted: state == "Booted")
            }
        }

        return SimulatorLaunchState(udid: udid, wasBooted: false)
    }

    nonisolated private static func bootSimulator(udid: String) throws {
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

    nonisolated private static func buildIOSProject(
        projectPath: String,
        scheme: String,
        configuration: String,
        destination: String,
        buildSettingOverrides: [String]
    ) throws {
        _ = try runCapturedCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", destination,
                "build",
            ] + buildSettingOverrides,
            currentDirectoryPath: URL(fileURLWithPath: projectPath).deletingLastPathComponent().path
        )
    }

    nonisolated private static func resolveIOSBuildArtifact(
        projectPath: String,
        scheme: String,
        configuration: String,
        destination: String,
        buildSettingOverrides: [String]
    ) throws -> IOSBuildArtifact {
        let result = try runCapturedCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-project", projectPath,
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", destination,
                "-showBuildSettings",
                "-json",
            ] + buildSettingOverrides,
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

    nonisolated private static func runCapturedCommand(
        executable: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath)
        }
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        SceneProcessRegistry.shared.register(process)
        defer { SceneProcessRegistry.shared.unregister(process) }
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
        case .bootIOSSimulator:
            return "Booting \(step.device ?? "Simulator")"
        case .launchIOSSimulatorApp:
            return "Launching \(step.scheme ?? step.bundleIdentifier ?? "iOS app") on \(step.device ?? "Simulator")"
        case .hideAllWindows:
            return "Hiding open windows"
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

    private func description(for action: SceneCleanupAction) -> String {
        switch action {
        case let .terminateApp(bundleIdentifier):
            return "Closing \(bundleIdentifier)"
        case .runShellCommand:
            return "Running cleanup command"
        case let .terminateIOSSimulatorApp(_, bundleIdentifier):
            return "Stopping \(bundleIdentifier) in Simulator"
        case .shutdownSimulator:
            return "Shutting down Simulator"
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
        isOverlayDismissed = false
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

    nonisolated private static func iosBuildSettingOverrides(for step: SceneStep) throws -> [String] {
        var overrides = step.buildSettingOverrides ?? []

        if let studioURL = normalizedString(step.studioURL) {
            overrides.append("INFOPLIST_KEY_WORKSTREAMSStudioURL=\(studioURL)")
        }

        switch step.authMode {
        case .disabled:
            guard let disabledAuthUserId = normalizedString(step.disabledAuthUserId) else {
                throw SceneRunnerError.invalidStep("disabledAuthUserId is required when iOS auth is disabled")
            }
            overrides.append("INFOPLIST_KEY_WORKSTREAMSDisableAuth=YES")
            overrides.append("INFOPLIST_KEY_WORKSTREAMSDisabledAuthUserId=\(disabledAuthUserId)")
        case .enabled:
            overrides.append("INFOPLIST_KEY_WORKSTREAMSDisableAuth=NO")
        case nil:
            break
        }

        return overrides
    }

    nonisolated private static func iosLaunchConfiguration(for step: SceneStep) throws -> IOSLaunchConfiguration {
        var environment: [String: String] = [:]
        var arguments: [String] = []

        if let studioURL = normalizedString(step.studioURL) {
            environment["SIMCTL_CHILD_WORKSTREAMS_STUDIO_URL"] = studioURL
            arguments.append(contentsOf: ["--workstreams-studio-url", studioURL])
        }

        switch step.authMode {
        case .disabled:
            guard let disabledAuthUserId = normalizedString(step.disabledAuthUserId) else {
                throw SceneRunnerError.invalidStep("disabledAuthUserId is required when iOS auth is disabled")
            }
            environment["SIMCTL_CHILD_DANGEROUSLY_DISABLE_AUTH"] = "1"
            environment["SIMCTL_CHILD_DISABLED_AUTH_USER_ID"] = disabledAuthUserId
            arguments.append("--dangerously-disable-auth")
            arguments.append(contentsOf: ["--disabled-auth-user-id", disabledAuthUserId])
        case .enabled:
            environment["SIMCTL_CHILD_DANGEROUSLY_DISABLE_AUTH"] = "0"
        case nil:
            break
        }

        return IOSLaunchConfiguration(environment: environment, arguments: arguments)
    }

    nonisolated private static func shouldBuildIOSArtifact(
        artifact: IOSBuildArtifact,
        launchConfiguration: IOSLaunchConfiguration,
        buildSettingOverrides: [String]
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: artifact.appPath) else {
            return true
        }

        let managedBuildSettingOverrides = Set(iosBuildSettingOverrideKeys)
        let hasUnmanagedBuildSettingOverrides = buildSettingOverrides.contains { override in
            guard let key = override.split(separator: "=", maxSplits: 1).first else {
                return true
            }
            return managedBuildSettingOverrides.contains(String(key)) == false
        }

        if hasUnmanagedBuildSettingOverrides {
            return true
        }

        guard launchConfiguration.requiresConfigValidation else {
            return false
        }

        if let persistedConfiguration = loadPersistedIOSLaunchConfiguration(for: artifact) {
            return persistedConfiguration != launchConfiguration
        }

        guard let infoDictionary = NSDictionary(contentsOf: URL(fileURLWithPath: artifact.appPath).appendingPathComponent("Info.plist")) as? [String: Any] else {
            return true
        }

        if let expectedStudioURL = launchConfiguration.studioURL {
            let actualStudioURL = normalizedString(infoDictionary["WORKSTREAMSStudioURL"])
            if actualStudioURL != expectedStudioURL {
                return true
            }
        }

        switch launchConfiguration.authMode {
        case .disabled:
            let actualDisableAuth = normalizedBooleanString(infoDictionary["WORKSTREAMSDisableAuth"])
            if actualDisableAuth != "yes" {
                return true
            }

            let actualDisabledAuthUserId = normalizedString(infoDictionary["WORKSTREAMSDisabledAuthUserId"])
            if actualDisabledAuthUserId != launchConfiguration.disabledAuthUserId {
                return true
            }
        case .enabled:
            let actualDisableAuth = normalizedBooleanString(infoDictionary["WORKSTREAMSDisableAuth"])
            if actualDisableAuth != "no" {
                return true
            }
        case nil:
            break
        }

        return false
    }

    nonisolated private static func normalizedString(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    nonisolated private static func normalizedBooleanString(_ value: Any?) -> String? {
        guard let normalized = normalizedString(value)?.lowercased() else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return "yes"
        case "0", "false", "no", "off":
            return "no"
        default:
            return normalized
        }
    }

    nonisolated private static func persistIOSLaunchConfiguration(_ configuration: IOSLaunchConfiguration, for artifact: IOSBuildArtifact) throws {
        guard configuration.requiresConfigValidation else {
            return
        }

        let data = try JSONEncoder().encode(configuration)
        try data.write(to: iosLaunchConfigurationURL(for: artifact), options: .atomic)
    }

    nonisolated private static func applyIOSLaunchConfiguration(_ configuration: IOSLaunchConfiguration, to artifact: IOSBuildArtifact) throws {
        guard configuration.requiresConfigValidation else {
            return
        }

        let plistURL = URL(fileURLWithPath: artifact.appPath).appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw SceneRunnerError.invalidBuildSettings
        }

        func plistBuddy(_ command: String) throws {
            _ = try runCapturedCommand(
                executable: "/usr/libexec/PlistBuddy",
                arguments: ["-c", command, plistURL.path]
            )
        }

        func addOrSetString(key: String, value: String) throws {
            do {
                try plistBuddy("Set :\(key) \(value)")
            } catch {
                try plistBuddy("Add :\(key) string \(value)")
            }
        }

        func addOrSetBool(key: String, value: Bool) throws {
            let plistValue = value ? "true" : "false"
            do {
                try plistBuddy("Set :\(key) \(plistValue)")
            } catch {
                try plistBuddy("Add :\(key) bool \(plistValue)")
            }
        }

        func deleteKeyIfPresent(_ key: String) {
            try? plistBuddy("Delete :\(key)")
        }

        if let studioURL = configuration.studioURL {
            try addOrSetString(key: "WORKSTREAMSStudioURL", value: studioURL)
        } else {
            deleteKeyIfPresent("WORKSTREAMSStudioURL")
        }

        switch configuration.authMode {
        case .disabled:
            try addOrSetBool(key: "WORKSTREAMSDisableAuth", value: true)
            if let disabledAuthUserId = configuration.disabledAuthUserId {
                try addOrSetString(key: "WORKSTREAMSDisabledAuthUserId", value: disabledAuthUserId)
            }
        case .enabled:
            try addOrSetBool(key: "WORKSTREAMSDisableAuth", value: false)
            deleteKeyIfPresent("WORKSTREAMSDisabledAuthUserId")
        case nil:
            if configuration.disabledAuthUserId == nil {
                deleteKeyIfPresent("WORKSTREAMSDisabledAuthUserId")
            }
        }
    }

    nonisolated private static func loadPersistedIOSLaunchConfiguration(for artifact: IOSBuildArtifact) -> IOSLaunchConfiguration? {
        let url = iosLaunchConfigurationURL(for: artifact)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(IOSLaunchConfiguration.self, from: data)
    }

    nonisolated private static func iosLaunchConfigurationURL(for artifact: IOSBuildArtifact) -> URL {
        URL(fileURLWithPath: artifact.appPath + ".scenes-launch-config.json")
    }

    nonisolated private static var iosBuildSettingOverrideKeys: [String] {
        [
            "INFOPLIST_KEY_WORKSTREAMSStudioURL",
            "INFOPLIST_KEY_WORKSTREAMSDisableAuth",
            "INFOPLIST_KEY_WORKSTREAMSDisabledAuthUserId",
        ]
    }

    nonisolated private static func inferredCleanupAction(for command: String?) -> SceneCleanupAction? {
        guard let command else { return nil }
        guard command.contains("npm run ops -- web start") || command.contains("npm run ops -- web restart") else {
            return nil
        }

        let prefix = command.components(separatedBy: "&& npm run ops --").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix, !prefix.isEmpty {
            return .runShellCommand("\(prefix) && npm run ops -- web stop")
        }

        return .runShellCommand("npm run ops -- web stop")
    }
}

private struct WindowGeometry {
    let position: CGPoint
    let size: CGSize
}

private struct ResolvedApplication {
    let url: URL
    let bundleIdentifier: String
}

private struct ResolvedOpenURL {
    let url: URL
    let bundleIdentifier: String
}

private struct IOSBuildArtifact {
    let appPath: String
    let bundleIdentifier: String?
}

private struct IOSSimulatorLaunchResult: Sendable {
    let udid: String
    let bundleIdentifier: String
}

private struct BootIOSSimulatorResult: Sendable {
    let udid: String
    let didOpenSimulatorApp: Bool
}

private struct SimulatorLaunchState: Sendable {
    let udid: String
    let wasBooted: Bool
}

private enum SceneCleanupAction: Hashable, Sendable {
    case terminateApp(bundleIdentifier: String)
    case runShellCommand(String)
    case terminateIOSSimulatorApp(udid: String, bundleIdentifier: String)
    case shutdownSimulator(udid: String)
}

private struct IOSLaunchConfiguration: Codable, Equatable {
    let environment: [String: String]
    let arguments: [String]
    let studioURL: String?
    let authMode: IOSAuthMode?
    let disabledAuthUserId: String?

    init(environment: [String: String], arguments: [String]) {
        self.environment = environment
        self.arguments = arguments
        self.studioURL = environment["SIMCTL_CHILD_WORKSTREAMS_STUDIO_URL"]
        self.authMode = {
            guard let value = environment["SIMCTL_CHILD_DANGEROUSLY_DISABLE_AUTH"] else {
                return nil
            }
            return value == "1" ? .disabled : .enabled
        }()
        self.disabledAuthUserId = environment["SIMCTL_CHILD_DISABLED_AUTH_USER_ID"]
    }

    var requiresConfigValidation: Bool {
        studioURL != nil || authMode != nil || disabledAuthUserId != nil
    }
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
