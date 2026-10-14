import SwiftUI

struct WindowPositionsView: View {
    @ObservedObject var module: WindowPositions
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Window positions").font(.headline)
            Text("Matches exact app bundle ID and window title. Duplicate or untitled windows are skipped. Only ordinary windows on the current desktop can be moved.").font(.caption)
            Button("Grant Accessibility access") { module.requestPermission() }
            TextField("Layout name", text: $name)
            Button("Save current layout") { module.save(name) }.disabled(!module.ready)
            Picker("Saved layout", selection: $module.selected) {
                Text("Select a layout").tag("")
                ForEach(module.layouts) { layout in Text(layout.name).tag(layout.id) }
            }
            HStack {
                Button("Restore now") { module.restore(module.selected) }.disabled(!module.ready || module.selected.isEmpty)
                Button("Delete") { module.delete(module.selected) }.disabled(module.selected.isEmpty)
            }
            Toggle("Restore after display reconnect or wake", isOn: $module.automatic)
            Toggle("Pause automatic restoration", isOn: $module.paused)
            TextField("Excluded bundle IDs, comma separated", text: $module.exclusions)
            Text("For multiple layouts on one display set, the selected layout wins. Pause affects automatic restoration only.").font(.caption)
            Text(module.summary).font(.caption).textSelection(.enabled)
        }
    }
}
