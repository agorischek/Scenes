import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()

    init(runner: SceneRunner) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 132),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = NSHostingController(
            rootView: SceneOverlayView()
                .environmentObject(runner)
        )
        panel.orderOut(nil)

        runner.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh(using: runner)
            }
            .store(in: &cancellables)
    }

    private func refresh(using runner: SceneRunner) {
        switch runner.executionState {
        case .idle:
            panel.orderOut(nil)
        case .running, .succeeded, .failed:
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = CGPoint(
            x: visibleFrame.maxX - panelSize.width - 22,
            y: visibleFrame.maxY - panelSize.height - 22
        )

        panel.setFrameOrigin(origin)
    }
}
