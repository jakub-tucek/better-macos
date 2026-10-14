import AppKit
import SwiftUI

/// One physical Q press can request at most one quit. Cancellation still consumes
/// repeats and the matching key-up, so a canceled hold cannot leak a normal ⌘Q.
struct QuitHoldState {
    private(set) var key: CGKeyCode?
    private(set) var target: pid_t?
    private(set) var started: TimeInterval = 0
    var duration: TimeInterval = 3

    mutating func keyDown(_ key: CGKeyCode, quitChord: Bool, repeated: Bool, target: pid_t?, now: TimeInterval) -> Bool {
        if self.key == key { return true }
        cancel()
        guard self.key == nil, quitChord, !repeated, let target else { return false }
        self.key = key
        self.target = target
        started = now
        return true
    }

    mutating func keyUp(_ key: CGKeyCode) -> Bool {
        guard self.key == key else { return false }
        reset()
        return true
    }

    mutating func cancel() { target = nil }
    mutating func reset() { cancel(); key = nil }
    func progress(at now: TimeInterval) -> Double {
        target == nil ? 0 : min(1, max(0, (now - started) / duration))
    }

    mutating func advance(now: TimeInterval, frontmost: pid_t?, keysHeld: Bool) -> pid_t? {
        guard keysHeld, target == frontmost else { cancel(); return nil }
        guard let target, progress(at: now) >= 1 else { return nil }
        cancel()
        return target
    }
}

final class QuitHUDModel: ObservableObject {
    @Published var name = ""
    @Published var icon: NSImage?
    @Published var startedAt: TimeInterval?
    @Published var duration = 3.0
}

/// Visual progress follows the same monotonic start time as the quit decision,
/// but draws at the animation cadence rather than stepping with the input timer.
struct QuitProgressFrame {
    let progress: Double
    let mouthAngle: Double

    init(startedAt: TimeInterval, duration: TimeInterval, now: TimeInterval) {
        let elapsed = max(0, now - startedAt)
        progress = min(1, elapsed / max(0.001, duration))
        mouthAngle = 5 + 35 * (0.5 + 0.5 * cos(elapsed * .pi * 8))
    }

    func centerX(width: Double) -> Double { 12 + max(0, width - 24) * progress }
    func remainingDots(width: Double) -> [Double] {
        let center = centerX(width: width)
        return (1...10).map { 12 + max(0, width - 24) * Double($0) / 10 }
            .filter { $0 > center + 5 }
    }
}

private struct QuitProgress: View {
    let startedAt: TimeInterval?
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let frame = QuitProgressFrame(startedAt: startedAt ?? now, duration: duration, now: now)
            Canvas { context, size in
                let center = CGPoint(x: frame.centerX(width: size.width), y: size.height / 2)
                for x in frame.remainingDots(width: size.width) {
                    let dot = Path(ellipseIn: CGRect(x: x - 2, y: center.y - 2, width: 4, height: 4))
                    context.fill(dot, with: .color(.secondary.opacity(0.6)))
                }
                var character = Path()
                character.move(to: center)
                character.addArc(center: center, radius: 10, startAngle: .degrees(frame.mouthAngle),
                                 endAngle: .degrees(360 - frame.mouthAngle), clockwise: false)
                character.closeSubpath()
                context.fill(character, with: .color(.yellow))
            }
            .accessibilityLabel("Quit progress")
            .accessibilityValue("\(Int(frame.progress * 100)) percent")
        }.frame(height: 28)
    }
}

struct QuitHUD: View {
    @ObservedObject var model: QuitHUDModel
    var body: some View {
        VStack(spacing: 12) {
            if let icon = model.icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48) }
            Text("Hold ⌘Q to quit \(model.name)").font(.headline).multilineTextAlignment(.center).lineLimit(2)
            QuitProgress(startedAt: model.startedAt, duration: model.duration)
            Text("Release to cancel").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 320)
    }
}

final class QuitGuard {
    private let defaults: UserDefaults
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var state = QuitHoldState()
    private var targetApp: NSRunningApplication?
    private var panel: NSPanel?
    private let hud = QuitHUDModel()
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var enabled: Bool { defaults.bool(forKey: "quitGuard.enabled") }
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var duration: Double {
        get {
            guard defaults.object(forKey: "quitGuard.duration") != nil else { return 3 }
            return Self.normalizedDuration(defaults.double(forKey: "quitGuard.duration"))
        }
        set { cancel(); defaults.set(Self.normalizedDuration(newValue), forKey: "quitGuard.duration"); onChange?() }
    }
    private static func normalizedDuration(_ seconds: Double) -> Double {
        seconds.isFinite ? min(99, max(1, seconds.rounded())) : 3
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try start() } else { stop() }
        defaults.set(enabled, forKey: "quitGuard.enabled")
        onChange?()
    }

    func startIfEnabled() throws { if enabled { try start() } }

    private func start() throws {
        guard !isRunning else { return }
        stop()
        guard AXIsProcessTrusted() else { throw ToggleError(message: "Hold to quit requires Accessibility access. Grant access, then enable it again.") }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<QuitGuard>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw ToggleError(message: "Could not enable Hold to quit. Check Accessibility access.")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ToggleError(message: "Could not start the quit shortcut listener.")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancel() })
        }
        onChange?()
    }

    private static func isCommandOnly(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Never finish a hold across an interruption in input observation.
            state.cancel()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DispatchQueue.main.async { [weak self] in self?.updatePresentation(); self?.onChange?() }
            return false
        }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        var consume = false
        switch type {
        case .keyDown:
            let chord = Self.isCommandOnly(event.flags) && NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() == "q"
            let app = NSWorkspace.shared.frontmostApplication
            let previous = state.target
            state.duration = duration
            consume = state.keyDown(key, quitChord: chord, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                    target: app?.processIdentifier, now: now)
            if previous == nil && state.target != nil { targetApp = app }
        case .keyUp: consume = state.keyUp(key)
        case .flagsChanged:
            if !Self.isCommandOnly(event.flags) { state.cancel() }
        default: state.cancel()
        }
        if consume || state.key != nil {
            DispatchQueue.main.async { [weak self] in self?.updatePresentation() }
        }
        return consume
    }

    private func updatePresentation() {
        if state.key != nil && timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        guard state.target != nil, let app = targetApp else {
            if hud.startedAt != nil { hud.startedAt = nil }
            panel?.orderOut(nil)
            targetApp = nil
            if state.key == nil { timer?.invalidate(); timer = nil }
            return
        }
        // App metadata and the animation epoch are set once per physical hold.
        // Repeats and input checks must not restart or invalidate the animation.
        if hud.startedAt != state.started {
            hud.name = app.localizedName ?? "this app"
            hud.icon = app.icon
            hud.duration = state.duration
            hud.startedAt = state.started
        }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 210),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            let background = NSVisualEffectView()
            background.material = .hudWindow
            background.state = .active
            background.blendingMode = .behindWindow
            background.wantsLayer = true
            background.layer?.cornerRadius = 18
            background.layer?.masksToBounds = true
            let host = NSHostingView(rootView: QuitHUD(model: hud))
            host.frame = background.bounds
            host.autoresizingMask = [.width, .height]
            background.addSubview(host)
            panel.contentView = background
            panel.isOpaque = false
            panel.backgroundColor = .clear
            self.panel = panel
        }
        if let panel, !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
            panel.orderFrontRegardless()
        }
    }

    private func tick() {
        guard let key = state.key else { updatePresentation(); return }
        let down = CGEventSource.keyState(.hidSystemState, key: key)
        let chord = Self.isCommandOnly(CGEventSource.flagsState(.hidSystemState))
        let app = targetApp
        let target = state.advance(now: now, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                   keysHeld: down && chord && isRunning && AXIsProcessTrusted())
        if !down { state.reset() }
        updatePresentation()
        // Normal termination honors unsaved-document prompts. Never force quit,
        // and never deliver the original shortcut to a newly foregrounded app.
        if let target, let app, app.processIdentifier == target, !app.isTerminated {
            if !app.terminate() { onError?(ToggleError(message: "\(app.localizedName ?? "The app") did not accept the quit request.")) }
        }
    }

    private func cancel() { state.cancel(); updatePresentation() }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        state.reset()
        targetApp = nil
        hud.startedAt = nil
        panel?.orderOut(nil)
        panel = nil
        onChange?()
    }

    deinit { stop() }
}
