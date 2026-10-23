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

/// A key-capable nonactivating panel keeps the destination app active. Selecting
/// an action closes the panel before the owner rechecks the captured AX identity.
final class WindowActionPaletteController {
    var isPresented: Bool { presenter.isPresented }
    private let presenter = ActionPalettePresenter()
    private var state = WindowActionPaletteState()
    private weak var owner: WindowPositions?
    private var target: WindowShortcutSession.Target?

    @discardableResult
    func show(owner: WindowPositions, target: WindowShortcutSession.Target?, message: String? = nil, orderFront: Bool = true) -> NSPanel {
        dismiss()
        self.owner = owner; self.target = target
        state = WindowActionPaletteState()
        let appName = target.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.window.app).first?.localizedName }
        let view = WindowActionPaletteView(state: state, targetName: appName ?? "Focused window", enabled: target != nil,
                                          hotkeysActive: owner.shortcutsActive,
                                          message: message ?? (target == nil ? owner.shortcutStatus : "Choose a layout. The window moves only when you select an action."),
                                          perform: { [weak self] in self?.apply($0) }, close: { [weak self] in self?.dismiss() })
        return presenter.show(title: "Window actions", preferredSize: NSSize(width: 760, height: 700), targetFrame: target?.window.frame,
                              orderFront: orderFront, handleKey: { [weak self] in self?.handle($0) ?? false }) { view }
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
        guard isPresented, let owner, let target else { return }
        dismiss()
        if !owner.applyAction(action, to: target), owner.canCapture {
            show(owner: owner, target: target, message: owner.shortcutStatus)
        }
    }

    func dismiss() {
        presenter.dismiss(); target = nil; owner = nil
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
        ActionPaletteLayout(title: "Window actions", subtitle: targetName, message: message,
                            leadingHint: "↑ ↓ ← → choose   ↩ apply   esc close",
                            trailingHint: hotkeysActive ? WindowShortcutAction.showActions.shortcut : "Hotkeys off · enable in Displays",
                            close: close) {
                WindowActionDiagram(action: state.preview)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.preview)
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(Array(WindowActionPaletteState.actions.enumerated()), id: \.element.id) { index, action in
                            ActionPaletteTile(title: action.title, detail: action.shortcut, selected: state.selection == index,
                                              action: { perform(action) }) { WindowActionDiagram(action: action) }
                                .disabled(!enabled)
                                .onHover { state.hovered = $0 ? action : nil }
                                .id(index)
                        }
                    }
                }.onChange(of: state.selection) { _, selection in proxy.scrollTo(selection) }
            }
        }
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
