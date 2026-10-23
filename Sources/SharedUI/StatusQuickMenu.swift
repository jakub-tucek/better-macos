import AppKit
import SwiftUI

enum StatusQuickAction: Int, CaseIterable {
    case windows, quickActions, keepAwake, settings, quit
}

final class StatusQuickMenuState: ObservableObject {
    @Published var selection = StatusQuickAction.windows
    @Published var windowsEnabled = false
    func enabled(_ action: StatusQuickAction) -> Bool { action != .windows || windowsEnabled }
    func step(_ direction: Int) {
        var index = selection.rawValue
        repeat { index = (index + direction + StatusQuickAction.allCases.count) % StatusQuickAction.allCases.count }
        while !enabled(StatusQuickAction(rawValue: index)!)
        selection = StatusQuickAction(rawValue: index)!
    }
}

private final class StatusQuickPanel: NSPanel {
    var handleKey: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }
}

/// Retains one fixed-size hosting tree. Presentation does not enter NSMenu's
/// tracking loop, animate, resize to content, or read feature/device state.
final class StatusQuickMenuController {
    static let size = NSSize(width: 304, height: 262)
    private(set) var isPresented = false
    private let state = StatusQuickMenuState()
    private var panel: StatusQuickPanel?
    private weak var anchor: NSView?
    private var localClick: Any?
    private var outsideClick: Any?
    private var activationObserver: NSObjectProtocol?
    private var choose: ((StatusQuickAction) -> Void)?

    @discardableResult
    func show(relativeTo anchor: NSView, windowsEnabled: Bool, orderFront: Bool = true,
              choose: @escaping (StatusQuickAction) -> Void) -> NSPanel {
        dismiss()
        self.anchor = anchor; self.choose = choose
        state.windowsEnabled = windowsEnabled
        state.selection = windowsEnabled ? .windows : .quickActions
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let anchorFrame = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero
        let visible = anchor.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let x = min(max(visible.minX + 8, anchorFrame.midX - Self.size.width / 2), visible.maxX - Self.size.width - 8)
        let y = max(visible.minY + 8, min(anchorFrame.minY - Self.size.height - 6, visible.maxY - Self.size.height - 6))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeFirstResponder(panel)
        isPresented = true
        guard orderFront else { return panel }
        panel.orderFrontRegardless()
        panel.makeKey()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if let anchor = self.anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
            self.dismiss()
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                              object: nil, queue: .main) { [weak self] _ in self?.dismiss() }
        return panel
    }

    private func makePanel() -> StatusQuickPanel {
        let panel = StatusQuickPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "Fix macOS quick menu"
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        backdrop.material = .popover; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 12; backdrop.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: StatusQuickMenuView(state: state) { [weak self] in self?.perform($0) })
        hosting.sizingOptions = []
        hosting.frame = backdrop.bounds; hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting); panel.contentView = backdrop
        panel.setContentSize(Self.size)
        panel.handleKey = { [weak self] in self?.handle($0) ?? false }
        return panel
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.keyCode == 53 { dismiss(); return true }
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if modifiers == [.shift], event.keyCode == 48 { state.step(-1); return true }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125, 124, 48: state.step(1)
        case 126, 123: state.step(-1)
        case 36, 76, 49: perform(state.selection)
        default: return false
        }
        return true
    }

    private func perform(_ action: StatusQuickAction) {
        guard isPresented, state.enabled(action), let choose else { return }
        dismiss()
        choose(action)
    }

    func dismiss() {
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        localClick = nil; outsideClick = nil; activationObserver = nil
        panel?.orderOut(nil)
        isPresented = false; anchor = nil; choose = nil
    }
    deinit { dismiss() }
}

struct StatusQuickMenuView: View {
    @ObservedObject var state: StatusQuickMenuState
    let choose: (StatusQuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fix macOS").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Quick menu").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 36)
            Divider().frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: 0) {
                row(.windows, title: "Window actions", detail: WindowShortcutAction.showActions.shortcut, symbol: "rectangle.split.2x2")
                row(.quickActions, title: "Quick actions", detail: "Your pinned controls", symbol: "slider.horizontal.3")
                row(.keepAwake, title: "Keep awake", detail: "Timers and sleep controls", symbol: "moon.zzz")
            }.padding(.horizontal, 8).padding(.vertical, 8)
            Divider().frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 8) {
                footer(.settings, title: "Settings", symbol: "gearshape")
                Spacer(minLength: 0)
                footer(.quit, title: "Quit", symbol: "power")
            }.padding(.horizontal, 8).frame(height: 46)
        }.frame(width: StatusQuickMenuController.size.width, height: StatusQuickMenuController.size.height)
    }

    private func row(_ action: StatusQuickAction, title: String, detail: String, symbol: String) -> some View {
        Button { choose(action) } label: {
            HStack(spacing: 12) {
                AppSymbolBadge(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 10).frame(height: 54)
                .background(state.selection == action ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).disabled(!state.enabled(action))
            .onHover { if $0 && state.enabled(action) { state.selection = action } }
            .accessibilityLabel(title)
            .accessibilityAddTraits(state.selection == action ? .isSelected : [])
    }

    private func footer(_ action: StatusQuickAction, title: String, symbol: String) -> some View {
        Button { choose(action) } label: {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(state.selection == action ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .onHover { if $0 { state.selection = action } }
            .accessibilityAddTraits(state.selection == action ? .isSelected : [])
    }
}
