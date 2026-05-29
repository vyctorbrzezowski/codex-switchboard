import AppKit
import Combine
import SwiftUI

private let statusBarSymbolName = "chart.bar.fill"

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let viewModel = UsageViewModel()
    private let authMirrorService = CodexAuthMirrorService()
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        authMirrorService.start()
        setupStatusItem()
        setupPopover()
        viewModel.refresh()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: statusBarSymbolName,
                          accessibilityDescription: "Codex Switchboard")
        img?.isTemplate = true
        button.image = img
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    // MARK: - Popover

    private func setupPopover() {
        let root = ContentView(viewModel: viewModel)
        let controller = NSHostingController(rootView: root)
        controller.preferredContentSize = preferredContentSize(for: viewModel.informationMode)
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [.preferredContentSize]
        }

        popover = NSPopover()
        popover.contentSize = preferredContentSize(for: viewModel.informationMode)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller

        viewModel.$informationMode
            .removeDuplicates()
            .sink { [weak self, weak controller] mode in
                let size = Self.preferredContentSize(for: mode)
                controller?.preferredContentSize = size
                self?.popover.contentSize = size
            }
            .store(in: &cancellables)
    }

    private func syncPopoverSizeToSelectedMode() {
        let size = preferredContentSize(for: viewModel.informationMode)
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
    }

    private static func preferredContentSize(for mode: AccountInformationMode) -> NSSize {
        NSSize(
            width: ContentView.preferredWidth(for: mode),
            height: ContentView.preferredHeight(for: mode)
        )
    }

    private func preferredContentSize(for mode: AccountInformationMode) -> NSSize {
        Self.preferredContentSize(for: mode)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            removeEventMonitor()
        } else {
            syncPopoverSizeToSelectedMode()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.popover.performClose(nil)
                self?.removeEventMonitor()
            }
        }
    }

    private func removeEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // hide from Dock
    app.run()
}
