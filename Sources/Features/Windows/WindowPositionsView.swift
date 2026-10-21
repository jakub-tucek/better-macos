import SwiftUI

struct WindowPositionsView: View {
    @ObservedObject var module: WindowPositions
    var setup = true
    @StoredState private var name = ""
    @StoredState private var renamingID: String?
    @StoredState private var renameDraft = ""
    @StoredState private var deletingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
          if setup {
            DashboardCard {
                DashboardSwitchRow(title: "Window keyboard shortcuts", isOn: Binding(get: { module.shortcutsEnabled }, set: { module.shortcutsEnabled = $0 }))
                    .font(.headline)
                Text("Rectangle-style controls for the focused window. Uses Accessibility; no extra app required.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(module.shortcutStatus).font(.caption).textSelection(.enabled)
                if module.shortcutsEnabled && !module.shortcutsActive {
                    Button("Retry shortcuts", action: module.retryShortcuts)
                }
                DisclosureGroup("Keyboard shortcuts") {
                    VStack(spacing: 8) {
                        ForEach(WindowShortcutAction.allCases) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                Text(action.shortcut).font(.system(.body, design: .monospaced))
                            }
                        }
                        Text("Letter keys use US key positions. Restore remembers up to 64 windows for this session. App size limits apply; full-screen windows and other Spaces are not supported.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 8)
                }
            }
          }
          DashboardCard {
            Label("Window positions", systemImage: DashboardTab.windows.symbol).font(.headline)
            if !module.permitted {
                Text("Accessibility access is required to move, save and restore windows.").font(.caption)
                Button("Grant Accessibility access") { module.requestPermission() }
            } else if !module.ready {
                Text("Waiting for stable displays and display-change confirmation.").font(.caption)
            } else {
                Text("Ready · current desktop only").font(.caption).foregroundStyle(.secondary)
            }

            if setup { VStack(alignment: .leading, spacing: 8) {
                TextField("New layout name", text: $name)
                    .onSubmit(save)
                Button("Save current layout", action: save)
                    .disabled(!module.canCapture || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } }
          }
          DashboardCard {
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
                        if setup { Menu {
                            Button("Rename…") { renameDraft = layout.name; renamingID = layout.id }
                            Button("Delete…", role: .destructive) { deletingID = layout.id }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Options for \(layout.name)")
                        }
                    }
                    if setup && renamingID == layout.id {
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
          }
           if setup { DashboardCard {
                DisclosureGroup("Advanced") {
                WindowPolicyControls(automatic: $module.automatic, paused: $module.paused, selected: $module.selected, exclusions: $module.exclusions, layouts: module.layouts).padding(.top, 8)
           } }
        }
        }
        .alert("Delete saved layout?", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } })) {
            Button("Delete", role: .destructive) { if let deletingID { module.delete(deletingID) }; deletingID = nil }
            Button("Cancel", role: .cancel) { deletingID = nil }
        } message: { Text("This removes the named layout, not any windows. It cannot be undone.") }
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
