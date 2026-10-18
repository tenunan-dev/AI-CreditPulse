import AICreditPulseCore
import AppKit
import Combine
import SwiftUI

/// The status-bar agent assembled with AppKit primitives (NSStatusBar +
/// NSPopover) instead of MenuBarExtra. Owned control over the button image —
/// we set NSImage directly, so no image-name resolution layer can silently
/// render an invisible item again (the recurring MenuBarExtra failure).
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var images: [String: NSImage] = [:]
    private var openMain: (() -> Void)?

    func install(openMain: @escaping () -> Void) {
        self.openMain = openMain
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = statusImage()
        button.action = #selector(togglePopover(_:))
        button.target = self
        // The dropdown also opens on right-click? Keep one behavior: any click toggles.
        self.item = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let content = NSHostingController(rootView: MenuBarContentView(openMain: openMain))
        popover.contentViewController = content
        // Hosting content may not have laid out yet; the dropdown's own width
        // is fixed at 400 + padding, so anchor those bounds and let height adapt.
        let fitting = content.view.fittingSize
        popover.contentSize = NSSize(
            width: max(404, fitting.width),
            height: max(480, fitting.height))
        popover.delegate = self
        self.popover = popover

        // Any published change re-tints the button: fresh snapshot, visibility
        // edits, .env edits — everything flows through objectWillChange.
        AppState.shared.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshImage() }
            .store(in: &cancellables)
    }

    /// The gauge tint carries the worst status of the user's visible rows.
    private func statusImage() -> NSImage? {
        let status = AppState.shared.visibleStatus
        let name = "icon-\(status.color)"
        if let cached = images[name] { return cached }
        guard let image = MenubarIcon.loadVerified(status.color) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        images[name] = image
        return images[name]
    }

    func refreshImage() {
        item?.button?.image = statusImage()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = item?.button, let popover else { return }
        Task { await AppState.shared.refresh() }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Position the needle under the status item and keep it transient.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Transient behaviour handles dismissal; nothing to reclaim yet.
    }
}
