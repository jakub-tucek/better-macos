import AppKit
import SwiftUI

final class WindowActionPaletteState: ObservableObject {
    static let actions: [WindowShortcutAction] = [
        .left, .right, .top, .bottom, .center,
        .topLeft, .topRight, .bottomLeft, .bottomRight, .maximize,
        .firstThird, .middleThird, .lastThird, .firstTwoThirds, .lastTwoThirds,
        .almostMaximize, .previousDisplay, .nextDisplay, .restore
    ]
    @Published var selection = 0
    @Published var hovered: WindowShortcutAction?
    var preview: WindowShortcutAction { hovered ?? Self.actions[selection] }
    func step(_ offset: Int) {
        selection = (selection + offset + Self.actions.count) % Self.actions.count
        hovered = nil
    }
}

private final class WindowActionPanel: NSPanel {
    var handleKey: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }
}

/// A key-capable nonactivating panel keeps the destination app active. Selecting
/// an action closes the panel before the owner rechecks the captured AX identity.
final class WindowActionPaletteController {
    var isPresented: Bool { panel != nil }
    private var panel: WindowActionPanel?
    private var outsideClick: Any?
    private var localClick: Any?
    private var activationObserver: NSObjectProtocol?
    private var state = WindowActionPaletteState()
    private weak var owner: WindowPositions?
    private var target: WindowShortcutSession.Target?

    @discardableResult
    func show(owner: WindowPositions, target: WindowShortcutSession.Target?, message: String? = nil, orderFront: Bool = true) -> NSPanel {
        dismiss()
        self.owner = owner; self.target = target
        state = WindowActionPaletteState()
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        func targetArea(_ screen: NSScreen) -> CGFloat {
            guard let target else { return 0 }
            let frame = screen.frame
            let intersection = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height).intersection(target.window.frame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        let targetScreen = screens.max { targetArea($0) < targetArea($1) }
        let screen = targetScreen.flatMap { targetArea($0) > 0 ? $0 : nil } ??
            screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: min(760, visible.width - 32), height: min(700, visible.height - 32))
        let panel = WindowActionPanel(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "Window actions"
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .hudWindow; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 20; backdrop.layer?.masksToBounds = true
        let appName = target.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.window.app).first?.localizedName }
        let view = WindowActionPaletteView(state: state, targetName: appName ?? "Focused window", enabled: target != nil,
                                          hotkeysActive: owner.shortcutsActive,
                                          message: message ?? (target == nil ? owner.shortcutStatus : "Choose a layout. The window moves only when you select an action."),
                                          perform: { [weak self] in self?.apply($0) }, close: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = backdrop.bounds; hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting); panel.contentView = backdrop
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        panel.handleKey = { [weak self] in self?.handle($0) ?? false }
        self.panel = panel
        panel.makeFirstResponder(panel)
        guard orderFront else { return panel }
        panel.makeKeyAndOrderFront(nil)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismiss() }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.dismiss() }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] _ in self?.dismiss() }
        return panel
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { dismiss(); return true }
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if modifiers == [.control, .option, .command], event.keyCode == 49 { dismiss(); return true }
        if modifiers.isEmpty {
            switch event.keyCode {
            case 123: state.step(-1)
            case 124: state.step(1)
            case 125: state.step(5)
            case 126: state.step(-5)
            case 48: state.step(1)
            case 36, 76, 49: apply(WindowActionPaletteState.actions[state.selection])
            default: return false
            }
            return true
        }
        if modifiers == [.shift], event.keyCode == 48 { state.step(-1); return true }
        return false
    }

    private func apply(_ action: WindowShortcutAction) {
        guard let owner, let target else { return }
        dismiss()
        if !owner.applyAction(action, to: target), owner.canCapture {
            show(owner: owner, target: target, message: owner.shortcutStatus)
        }
    }

    func dismiss() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        outsideClick = nil; localClick = nil; activationObserver = nil
        panel?.orderOut(nil); panel = nil; target = nil; owner = nil
    }
    deinit { dismiss() }
}

struct WindowActionPaletteView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: WindowActionPaletteState
    let targetName: String
    let enabled: Bool
    let hotkeysActive: Bool
    let message: String
    let perform: (WindowShortcutAction) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                WindowActionDiagram(action: state.preview).frame(width: 72, height: 46)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.preview)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Window actions").font(.system(size: 24, weight: .semibold))
                    Text(targetName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").padding(8) }
                    .buttonStyle(.plain).accessibilityLabel("Close window actions")
            }
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(Array(WindowActionPaletteState.actions.enumerated()), id: \.element.id) { index, action in
                            Button { perform(action) } label: {
                                VStack(spacing: 7) {
                                    WindowActionDiagram(action: action).frame(width: 44, height: 28)
                                    Text(action.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                        .frame(height: 28).multilineTextAlignment(.center)
                                    Text(action.shortcut).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(state.selection == index ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state.selection == index ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06)))
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).disabled(!enabled)
                                .accessibilityLabel("\(action.title), \(action.shortcut)")
                                .accessibilityAddTraits(state.selection == index ? .isSelected : [])
                                .onHover { state.hovered = $0 ? action : nil }
                                .id(index)
                        }
                    }
                }.onChange(of: state.selection) { _, selection in proxy.scrollTo(selection) }
            }
            Divider()
            HStack {
                Text("↑ ↓ ← → choose   ↩ apply   esc close")
                Spacer()
                Text(hotkeysActive ? WindowShortcutAction.showActions.shortcut : "Hotkeys off · enable in Displays")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(24)
    }
}

struct WindowActionDiagram: View {
    let action: WindowShortcutAction
    private var symbol: String? {
        switch action {
        case .previousDisplay: return "arrow.left"
        case .nextDisplay: return "arrow.right"
        case .restore: return "arrow.uturn.backward"
        default: return nil
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let original = bounds.insetBy(dx: bounds.width * 0.22, dy: bounds.height * 0.22)
            let destination = action.destination(for: original, displays: [WindowDisplay(id: "preview", bounds: bounds)]) ?? original
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5))
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                        .frame(width: bounds.width, height: bounds.height).foregroundStyle(.secondary)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor.opacity(0.8)))
                        .frame(width: max(1, destination.width - 4), height: max(1, destination.height - 4))
                        .offset(x: destination.minX + 2, y: destination.minY + 2)
                }
            }
        }.accessibilityHidden(true)
    }
}
