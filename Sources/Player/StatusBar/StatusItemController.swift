import AppKit
import OSLog
import ServiceManagement
import SwiftUI

private let log = Logger(subsystem: "com.workbyoliver.Player", category: "StatusItem")

/// Owns the menu bar item and routes its interactions:
/// click → glass panel · ⌥-click → play/pause · right-click → menu · scroll → volume · hover → marquee.
///
/// macOS 26+ hosts menu bar items in a system process and forwards only clicks, without
/// modifier flags. So hover and scroll are detected with event monitors and a pointer
/// hit test, and ⌥ is read from the live keyboard state.
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let nowPlaying: NowPlayingService
    private let volume: VolumeService
    private let appVolumes: AppVolumes
    private let state = StatusItemState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let content = StatusItemContentView()
    private var panelHost: NSHostingView<NowPlayingPanelView>!
    private var panel: GlassPanel!
    private var panelClosedAt = Date.distantPast
    private var panelSize = CGSize.zero
    private var eventMonitors: [Any] = []
    private var trackpadScroll: CGFloat = 0
    private var hideVolumeFeedback: DispatchWorkItem?

    init(nowPlaying: NowPlayingService, volume: VolumeService, appVolumes: AppVolumes) {
        self.nowPlaying = nowPlaying
        self.volume = volume
        self.appVolumes = appVolumes
        super.init()
        setUpButton()
        setUpPanel()
        setUpEventMonitors()
        followMenuBarState()
    }

    // MARK: - Setup

    private func setUpButton() {
        guard let button = statusItem.button else { return }
        let container = PassthroughView()
        container.addSubview(content)
        button.addSubview(container)
        for (view, parent) in [(container, button), (content, container)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                view.topAnchor.constraint(equalTo: parent.topAnchor),
                view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
        }
        // The button sizes itself from its title/image, and it has neither, so it would
        // collapse to 0pt tall. Give it the menu bar's height.
        container.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness).isActive = true
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setUpPanel() {
        let view = NowPlayingPanelView(nowPlaying: nowPlaying, volume: volume, appVolumes: appVolumes, state: state) { [weak self] size in
            self?.panelSizeChanged(size)
        }
        panelHost = NSHostingView(rootView: view)
        panelHost.sizingOptions = [] // the controller sizes the panel (see positionPanel)
        panel = GlassPanel(content: panelHost)
        panel.delegate = self
    }

    private func setUpEventMonitors() {
        // Scroll over the item → volume. Global because the system menu bar host receives
        // these, local in case they ever reach us directly.
        let scrollGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isPointerOverItem else { return }
            self.adjustVolume(with: event)
        }
        let scrollLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isPointerOverItem else { return event }
            self.adjustVolume(with: event)
            return nil
        }
        // Hover → marquee.
        let hoverGlobal = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.updateHover()
        }
        let hoverLocal = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateHover()
            return event
        }
        // A click anywhere else closes the panel (clicks on the item toggle it instead).
        let outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible, !self.isPointerOverItem else { return }
            self.closePanel()
        }
        // Panel keys: Escape closes it, Space plays/pauses.
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            switch event.keyCode {
            case 53: self.closePanel()
            case 49: self.nowPlaying.send(.toggle)
            default: return event
            }
            return nil
        }
        eventMonitors = [scrollGlobal, scrollLocal, hoverGlobal, hoverLocal, outsideClick, keys].compactMap { $0 }
    }

    // MARK: - Menu bar content

    /// Pushes what the menu bar should show into the AppKit content view, and sizes the
    /// item to fit, whenever the track, artwork, hover or volume overlay changes.
    private func followMenuBarState() {
        withObservationTracking {
            let track = nowPlaying.track
            content.content = StatusItemContentView.Content(
                text: track?.menuBarText,
                isPlaying: track?.isPlaying == true,
                palette: nowPlaying.palette,
                volumeFeedback: state.volumeFeedback,
                isHovering: state.isHovering
            )
            let width = StatusItemLayout.itemWidth(text: track?.menuBarText)
            if statusItem.length != width { statusItem.length = width }
            statusItem.button?.setAccessibilityTitle(track?.menuBarText ?? "Nothing playing")
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.followMenuBarState() }
        }
    }

    // MARK: - Mouse

    @objc private func handleClick() {
        // No mouse event when pressed via accessibility (e.g. VoiceOver): treat as a plain click.
        let event = NSApp.currentEvent
        let flags = event == nil ? [] : NSEvent.modifierFlags
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu()
        } else if flags.contains(.option) {
            nowPlaying.send(.toggle)
        } else {
            togglePanel()
        }
    }

    private func updateHover() {
        let isOver = isPointerOverItem
        if isOver != state.isHovering { state.isHovering = isOver }
    }

    /// The item's on-screen rect, padded to the full menu bar height.
    private var itemRect: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: 0, dy: -4)
    }

    private var isPointerOverItem: Bool {
        itemRect?.contains(NSEvent.mouseLocation) ?? false
    }

    private func adjustVolume(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return } // no runaway volume after a flick

        // Same physical direction regardless of the natural-scrolling setting: up = louder.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Trackpad: about 300pt of travel for the full range.
            trackpadScroll += delta
            let step = Float(trackpadScroll) * 0.0033
            guard abs(step) >= 0.01 else { return }
            trackpadScroll = 0
            nudgeVolume(by: step)
        } else {
            // Mouse wheel: one notch = one volume-key step (1/16).
            nudgeVolume(by: Float(max(-4, min(4, delta))) / 16)
        }
        showVolumeFeedback()
    }

    /// The selected app's volume, like the panel's slider; the Mac's with nothing selected.
    private func nudgeVolume(by delta: Float) {
        if let source = nowPlaying.selectedSource {
            appVolumes.nudge(by: delta, for: source)
        } else {
            volume.nudgeVolume(by: delta)
        }
    }

    private func showVolumeFeedback() {
        if let source = nowPlaying.selectedSource {
            state.volumeFeedback = appVolumes.level(for: source)
        } else if let level = volume.volume {
            state.volumeFeedback = volume.isMuted ? 0 : level
        } else {
            return
        }
        hideVolumeFeedback?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.state.volumeFeedback = nil }
        hideVolumeFeedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: - Panel

    private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(panelClosedAt) > 0.3 {
            // (Otherwise this click on the item is what just closed it.)
            showPanel()
        }
    }

    private func showPanel() {
        state.isPanelOpen = true
        panel.attachContent()
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.refreshShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.refreshShadow() } // AppKit calls this on the main thread
        }
        statusItem.button?.highlight(true)
    }

    private func closePanel() {
        guard panel.isVisible, state.isPanelOpen else { return }
        state.isPanelOpen = false
        panelClosedAt = Date()
        statusItem.button?.highlight(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { // AppKit calls this on the main thread
                guard let self, !self.state.isPanelOpen else { return } // reopened meanwhile
                self.panel.orderOut(nil)
                self.panel.detachContent()
            }
        }
    }

    /// The SwiftUI content reports its size whenever it changes (open or not).
    private func panelSizeChanged(_ size: CGSize) {
        panelSize = size
        if panel.isVisible {
            positionPanel(keepingHorizontalPosition: true)
        } else {
            // First layout at launch: now that the size is known, detach until opened.
            DispatchQueue.main.async { [weak self] in self?.panel.detachContent() }
        }
    }

    /// Sizes the panel to its content and hangs it 6pt below the menu bar, its left edge
    /// lined up with the item's, kept on screen. The item moves as its title and other menu
    /// bar items change, so this lines up on every open, then only grows or shrinks
    /// vertically while open, so the panel never slides sideways under you.
    private func positionPanel(keepingHorizontalPosition: Bool = false) {
        guard panelSize.width > 0, panelSize.height > 0, let itemRect else { return }
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        let preferredX = keepingHorizontalPosition ? panel.frame.minX : itemRect.minX
        let x = min(max(preferredX, visible.minX + 8), visible.maxX - panelSize.width - 8)
        let top = visible.maxY - 6
        panel.setFrame(NSRect(x: x, y: top - panelSize.height, width: panelSize.width, height: panelSize.height), display: true)
        panel.refreshShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel() // you moved on to another app or window
    }

    // MARK: - Menu

    private func showMenu() {
        closePanel()
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil) // opens the menu with native menu bar styling
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil // so the next left click opens the panel again
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        if let track = nowPlaying.track {
            let current = NSMenuItem(title: track.menuBarText, action: nil, keyEquivalent: "")
            current.isEnabled = false
            if let artwork = nowPlaying.artwork { current.image = artwork.resized(to: 16) }
            menu.addItem(current)
            menu.addItem(ActionMenuItem(title: track.isPlaying ? "Pause" : "Play") { [weak self] in
                self?.nowPlaying.send(.toggle)
            })
            menu.addItem(ActionMenuItem(title: "Next Track") { [weak self] in self?.nowPlaying.send(.next) })
            menu.addItem(ActionMenuItem(title: "Previous Track") { [weak self] in self?.nowPlaying.send(.prev) })
            if let source = nowPlaying.source {
                let open = ActionMenuItem(title: "Open \(source.name)") {
                    NSWorkspace.shared.openApplication(at: source.url, configuration: .init())
                }
                open.image = source.icon.resized(to: 16)
                menu.addItem(open)
            }
            menu.addItem(.separator())
        }

        if nowPlaying.sources.count > 1 {
            for source in nowPlaying.sources {
                let item = ActionMenuItem(title: source.name) { [weak self] in self?.nowPlaying.select(source) }
                item.image = source.app?.icon.resized(to: 16)
                item.state = source.id == nowPlaying.selectedSourceID ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let login = ActionMenuItem(title: "Launch at Login") { Self.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Quit Player", keyEquivalent: "q") { NSApp.terminate(nil) })
        return menu
    }

    private static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.error("Launch at Login failed: \(error.localizedDescription, privacy: .public)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// Holds the SwiftUI content inside the status bar button without swallowing its clicks.
/// (A container rather than an NSHostingView subclass: the generic subclass crashes the
/// Swift 6.3 optimizer in release builds.)
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An NSMenuItem that runs a closure. (A factory rather than an NSMenuItem subclass:
/// subclassing clashes with NSMenuItem's nonisolated initializers.)
private func ActionMenuItem(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: keyEquivalent)
    let action = MenuAction(handler)
    item.target = action
    item.representedObject = action // NSMenuItem.target is weak; this keeps the action alive
    return item
}

private final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run(_ sender: NSMenuItem) { handler() }
}

private extension NSImage {
    func resized(to side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
    }
}
