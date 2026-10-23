import AppKit
import SwiftUI

private final class ActionPalettePanel: NSPanel {
    var handleKey: (NSEvent) -> Bool = { _ in false }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }
}

/// Shared native lifetime for centered action palettes. Feature owners keep all
/// action policy; this module owns material, sizing, focus and dismissal observers.
final class ActionPalettePresenter {
    var isPresented: Bool { panel != nil }
    private var panel: ActionPalettePanel?
    private var outsideClick: Any?
    private var localClick: Any?
    private var activationObserver: NSObjectProtocol?

    @discardableResult
    func show<Content: View>(title: String, preferredSize: NSSize, targetFrame: CGRect? = nil,
                             orderFront: Bool = true, handleKey: @escaping (NSEvent) -> Bool,
                             @ViewBuilder content: () -> Content) -> NSPanel {
        dismiss()
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        func targetArea(_ screen: NSScreen) -> CGFloat {
            guard let targetFrame else { return 0 }
            let frame = screen.frame
            let intersection = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height).intersection(targetFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        let targetScreen = screens.max { targetArea($0) < targetArea($1) }
        let screen = targetScreen.flatMap { targetArea($0) > 0 ? $0 : nil } ??
            screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: min(preferredSize.width, visible.width - 32), height: min(preferredSize.height, visible.height - 32))
        let panel = ActionPalettePanel(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = title
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        backdrop.material = .hudWindow; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 20; backdrop.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: content())
        hosting.frame = backdrop.bounds; hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting); panel.contentView = backdrop
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        panel.handleKey = { [weak self] event in
            guard self?.isPresented == true else { return false }
            if event.keyCode == 53 { self?.dismiss(); return true }
            return handleKey(event)
        }
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
    func dismiss() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let localClick { NSEvent.removeMonitor(localClick) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        outsideClick = nil; localClick = nil; activationObserver = nil
        panel?.orderOut(nil); panel = nil
    }
    deinit { dismiss() }
}

struct ActionPaletteLayout<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    let message: String
    let leadingHint: String
    let trailingHint: String
    let close: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                icon().frame(width: 72, height: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 24, weight: .semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").padding(8) }
                    .buttonStyle(.plain).accessibilityLabel("Close \(title)")
            }
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
            Divider()
            HStack {
                Text(leadingHint)
                Spacer()
                Text(trailingHint)
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(24).onExitCommand(perform: close)
    }
}

struct ActionPaletteTile<Icon: View>: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                icon().frame(width: 44, height: 28)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    .frame(height: 28).multilineTextAlignment(.center)
                Text(detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("\(title), \(detail)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
