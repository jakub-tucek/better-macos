import SwiftUI

// Compile with the production alias, not a second copy of its definition.
private struct StoredStateCompilerFixture: View {
    @StoredState private var text = ""
    @StoredState private var selection: String?
    @StoredState private var positions: [CGPoint]

    init(positions: [CGPoint]) {
        _positions = State(initialValue: positions)
    }

    var body: some View {
        TextField("Draft", text: $text)
        Toggle("Selected", isOn: Binding(get: { selection != nil }, set: { selection = $0 ? text : nil }))
        Text("\(positions.count)")
    }
}
