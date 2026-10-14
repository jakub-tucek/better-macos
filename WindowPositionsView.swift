import SwiftUI

struct WindowPositionsView: View {
    @ObservedObject var module: WindowPositions
    @State private var name = ""
    @State private var renamingID: String?
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Window positions", systemImage: DashboardTab.windows.symbol).font(.headline)
            if !module.permitted {
                Text("Accessibility access is required to save and restore windows.").font(.caption)
                Button("Grant Accessibility access") { module.requestPermission() }
            } else if !module.ready {
                Text("Waiting for stable displays and display-change confirmation.").font(.caption)
            } else {
                Text("Ready · current desktop only").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("New layout name", text: $name)
                    .onSubmit(save)
                Button("Save current layout", action: save)
                    .disabled(!module.canCapture || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            if module.layouts.isEmpty {
                Text("No saved layouts yet.").foregroundStyle(.secondary)
            } else {
                ForEach(module.layouts) { layout in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(layout.name).font(.headline).lineLimit(2)
                            Text("\(layout.windows.count) windows · \(layout.displays.count) displays")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Restore") { module.restore(layout.id) }
                            .disabled(!module.canCapture)
                            .accessibilityLabel("Restore \(layout.name)")
                        Menu {
                            Button("Rename…") { renameDraft = layout.name; renamingID = layout.id }
                            Button("Delete", role: .destructive) { module.delete(layout.id) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Options for \(layout.name)")
                    }
                    if renamingID == layout.id {
                        HStack {
                            TextField("Layout name", text: $renameDraft).onSubmit(rename)
                            Button("Save", action: rename)
                                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { renamingID = nil }
                        }
                    }
                    Divider()
                }
            }
            Text(module.summary).font(.caption).textSelection(.enabled)

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    switchRow("Restore after reconnect or wake", value: $module.automatic)
                    switchRow("Pause automatic restoration", value: $module.paused)
                    Picker("Automatic layout", selection: $module.selected) {
                        Text("Use unique matching layout").tag("")
                        ForEach(module.layouts) { Text($0.name).tag($0.id) }
                    }
                    Text("With several layouts for the same displays, choose one for automatic restore. Pause does not block manual Restore.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Excluded bundle IDs, comma separated", text: $module.exclusions)
                    Text("Exact app and window-title matches only. Ambiguous, untitled, and unsupported windows are skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }

    private func switchRow(_ label: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(label)
            Spacer()
            BlueSwitch(label: label, isOn: value)
        }
    }

    private func save() {
        let count = module.layouts.count
        module.save(name)
        if module.layouts.count > count { name = "" }
    }

    private func rename() {
        guard let id = renamingID, module.rename(id, to: renameDraft) else { return }
        renamingID = nil
    }
}
