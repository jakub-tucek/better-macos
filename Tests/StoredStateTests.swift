import AppKit
import SwiftUI

private final class StoredStateProbe {
    var text: Binding<String>?
    var selection: Binding<String?>?
    var draft: Binding<AwakeDurationDraft>?
    var renders = 0

    func capture(text: Binding<String>, selection: Binding<String?>, draft: Binding<AwakeDurationDraft>) {
        self.text = text
        self.selection = selection
        self.draft = draft
        renders += 1
    }
}

private struct StoredStateTestView: View {
    let probe: StoredStateProbe
    @StoredState private var text = "initial"
    @StoredState private var selection: String?
    @StoredState private var draft: AwakeDurationDraft

    init(minutes: Int, probe: StoredStateProbe) {
        self.probe = probe
        _draft = State(initialValue: AwakeDurationDraft(minutes: minutes))
    }

    var body: some View {
        probe.capture(text: $text, selection: $selection, draft: $draft)
        return Text("\(text) / \(selection ?? "nil") / \(draft.text)")
    }
}

func runStoredStateTests() {
    // Only an unpresented, owned hosting window: no app delegate, permissions or OS backends.
    _ = NSApplication.shared
    let probe = StoredStateProbe()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: StoredStateTestView(minutes: 30, probe: probe).id(0))
    window.contentView = view
    defer { window.contentView = nil; window.close() }
    func settle() {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            window.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    settle()
    expect(probe.text?.wrappedValue == "initial" && probe.selection?.wrappedValue == nil && probe.draft?.wrappedValue.text == "30",
           "mounted compatibility wrapper initializes values, nil optionals and explicit editor storage")
    let renders = probe.renders
    probe.text?.wrappedValue = "edited"
    probe.selection?.wrappedValue = "layout-id"
    probe.draft?.wrappedValue.text = "invalid draft"
    settle()
    expect(probe.renders > renders, "projected compatibility bindings invalidate the native SwiftUI view")
    expect(probe.text?.wrappedValue == "edited" && probe.selection?.wrappedValue == "layout-id" && probe.draft?.wrappedValue.text == "invalid draft",
           "projected bindings write string, optional selection and value-type editor draft")
    view.rootView = StoredStateTestView(minutes: 45, probe: probe).id(0)
    settle()
    expect(probe.text?.wrappedValue == "edited" && probe.selection?.wrappedValue == "layout-id" && probe.draft?.wrappedValue.text == "invalid draft",
           "same native view identity preserves edits despite replacement initializer inputs")
    probe.selection?.wrappedValue = nil
    settle()
    expect(probe.selection?.wrappedValue == nil, "optional projected state supports clearing a selection")
    view.rootView = StoredStateTestView(minutes: 45, probe: probe).id(1)
    settle()
    expect(probe.text?.wrappedValue == "initial" && probe.selection?.wrappedValue == nil && probe.draft?.wrappedValue.text == "45",
           "new native view identity discards old local state and initializes a fresh draft")
}
