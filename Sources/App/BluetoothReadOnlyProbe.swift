import AppKit
import CoreFoundation

enum ApplicationLaunchMode: Equatable {
    case normal, bluetoothReadOnlyProbe

    init(arguments: [String]) {
        self = arguments.contains("--bluetooth-readonly-probe") ? .bluetoothReadOnlyProbe : .normal
    }

    // Factories are lazy: probe launch must not even construct the normal host.
    func delegate(normal: () -> NSApplicationDelegate, probe: () -> NSApplicationDelegate) -> NSApplicationDelegate {
        switch self {
        case .normal: return normal()
        case .bluetoothReadOnlyProbe: return probe()
        }
    }
}

/// Capabilities intentionally contain only preference reads and native getters.
/// No feature owner, host transaction, central manager or command runner exists.
struct BluetoothReadOnlyProbeRun {
    let readValue: (String) -> Any?
    let makeProbe: () -> BluetoothControlProbe
    let diagnostics: Diagnostics
    var isAppBundle: () -> Bool = { true }

    static func live(diagnostics: Diagnostics = .shared) -> Self {
        Self(readValue: { key in
            CFPreferencesCopyAppValue(key as CFString, "io.github.jakub-tucek.better-macos" as CFString)
        }, makeProbe: { .live(diagnostics: diagnostics) }, diagnostics: diagnostics, isAppBundle: {
            Bundle.main.bundleIdentifier == "io.github.jakub-tucek.better-macos" && Bundle.main.bundleURL.pathExtension == "app"
        })
    }

    func run(operation: String, shouldContinue: () -> Bool) -> [String: String] {
        let started = diagnostics.start()
        diagnostics.emit("bluetooth", "readonly_probe_begin", operation: operation,
                         fields: ["scope": "same_bundle_gui", "control_capability": "unverified"])
        func finish(_ fields: [String: String]) -> [String: String] {
            diagnostics.emit("bluetooth", "readonly_probe_result", outcome: fields["probe_stage"] ?? "unknown",
                             operation: operation, since: started, fields: fields)
            return fields
        }
        func addresses(_ key: String) -> Set<String>? {
            guard let value = readValue(key) else { return [] }
            guard let array = value as? [String] else { return nil }
            let identities = array.compactMap(BluetoothIdentity.canonical)
            guard identities.count == array.count, Set(identities).count == array.count else { return nil }
            return Set(identities)
        }
        guard shouldContinue() else { return finish(["probe_stage": "canceled", "control_capability": "unverified"]) }
        guard isAppBundle() else { return finish(["probe_stage": "not_app_bundle", "saved_count": "unknown", "protected_count": "unknown", "control_capability": "unverified"]) }
        guard let saved = addresses("bluetooth.autoAddresses"), let protected = addresses("bluetooth.protectedAudioAddresses") else {
            return finish(["probe_stage": "invalid_saved_identity", "saved_count": "unknown", "protected_count": "unknown", "control_capability": "unverified"])
        }
        // No profiler/helper subprocess and no pairedDevices enumeration. Only
        // registered targets are queried; this does not prove full protection inventory.
        let fields = makeProbe().inspect(saved: saved, protected: protected, inventory: nil,
                                         shouldContinue: shouldContinue, operation: operation, level: .info)
        return finish(fields ?? ["probe_stage": "canceled", "control_capability": "unverified"])
    }
}

final class BluetoothReadOnlyProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let run: BluetoothReadOnlyProbeRun
    private let work: (@escaping () -> Void) -> Void
    private let present: ((String) -> Void)?
    private let cancellation = BluetoothProbeCancellation()
    private var started = false
    private(set) var resultText: String?
    private var window: NSWindow?

    init(run: BluetoothReadOnlyProbeRun = .live(),
         work: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         present: ((String) -> Void)? = nil) {
        self.run = run
        self.work = work
        self.present = present
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !started else { return }
        started = true
        let operation = UUID().uuidString
        let identity = "Run: \(operation)\nSession: \(run.diagnostics.session)\nPID: \(ProcessInfo.processInfo.processIdentifier)"
        show("Read-only Bluetooth probe running.\n\(identity)\nNo automations started.")
        let run = run, cancellation = cancellation
        work { [weak self] in
            let fields = run.run(operation: operation, shouldContinue: { !cancellation.isCanceled })
            DispatchQueue.main.async {
                guard !cancellation.isCanceled, let self else { return }
                let keys = ["probe_stage", "documented_controller_state", "saved_count", "saved_paired_true_count", "protected_count", "protected_paired_true_count", "connected_true_count", "control_capability"]
                let text = "Read-only Bluetooth probe complete.\n\(identity)\n" + keys.map { "\($0): \(fields[$0] ?? "unknown")" }.joined(separator: "\n") + "\nNo automations started. Quit when done."
                self.resultText = text
                self.show(text)
            }
        }
    }

    private func show(_ text: String) {
        if let present { present(text); return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Better macOS · Read-only Bluetooth probe"
            window.isReleasedWhenClosed = false
            window.delegate = self
            let label = NSTextField(wrappingLabelWithString: text)
            label.frame = NSRect(x: 20, y: 20, width: 580, height: 300)
            label.isSelectable = true
            window.contentView?.addSubview(label)
            window.center()
            self.window = window
        } else if let label = window?.contentView?.subviews.first as? NSTextField { label.stringValue = text }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancellation.cancel()
        return .terminateNow // No feature owner was constructed; nothing to restore.
    }

    func applicationWillTerminate(_ notification: Notification) { cancellation.cancel() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private final class BluetoothProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    func cancel() { lock.lock(); canceled = true; lock.unlock() }
    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
}
