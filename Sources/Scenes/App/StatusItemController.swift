import AppKit
import SwiftUI

@MainActor
final class StatusItemController {
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    init() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 420)
    }

    func install<Content: View>(rootView: Content, target: AnyObject, action: Selector) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = target
        statusItem.button?.action = action
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.image = NSImage(
            systemSymbolName: "sparkles.rectangle.stack",
            accessibilityDescription: "Scenes"
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Scenes"

        self.statusItem = statusItem
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    func togglePopover(sender: AnyObject?) {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: anchorRect(for: button), of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover(sender: AnyObject? = nil) {
        if popover.isShown {
            popover.performClose(sender)
        }
    }

    private func anchorRect(for button: NSStatusBarButton) -> NSRect {
        if let cell = button.cell {
            let imageRect = cell.imageRect(forBounds: button.bounds)
            if !imageRect.isEmpty {
                return imageRect.insetBy(dx: -6, dy: 0)
            }
        }

        let side = min(button.bounds.width, button.bounds.height)
        let origin = NSPoint(
            x: button.bounds.midX - (side / 2),
            y: button.bounds.midY - (side / 2)
        )
        return NSRect(origin: origin, size: NSSize(width: side, height: side)).insetBy(dx: -4, dy: 0)
    }
}
