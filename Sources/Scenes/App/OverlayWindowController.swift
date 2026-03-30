import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var hasPlacedPanel = false
    private var isFadingOut = false

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
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = NSHostingController(
            rootView: SceneOverlayView()
                .environmentObject(runner)
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14
        panel.contentView?.layer?.masksToBounds = true
        panel.alphaValue = 0
        panel.orderOut(nil)

        runner.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh(using: runner)
            }
            .store(in: &cancellables)
    }

    private func refresh(using runner: SceneRunner) {
        if runner.isOverlayDismissed {
            hidePanel(animated: true)
            return
        }

        switch runner.executionState {
        case .idle:
            hidePanel(animated: true)
            hasPlacedPanel = false
        case .running, .succeeded, .failed:
            if hasPlacedPanel == false || panel.isVisible == false {
                positionPanel()
                hasPlacedPanel = true
            }
            showPanel()
        }
    }

    private func showPanel() {
        isFadingOut = false
        panel.animator().alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hidePanel(animated: Bool) {
        guard panel.isVisible || panel.alphaValue > 0 else { return }
        guard !isFadingOut else { return }

        if !animated {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isFadingOut = false
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
