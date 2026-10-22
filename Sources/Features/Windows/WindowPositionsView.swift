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
                Text("Move the focused window with Rectangle-style shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach([WindowShortcutAction.left, .right, .maximize, .center]) { action in
                        WindowShortcutTile(action: action)
                    }
                }
                Text(module.shortcutStatus).font(.caption).textSelection(.enabled)
                if module.shortcutsEnabled && !module.shortcutsActive {
                    Button("Retry shortcuts", action: module.retryShortcuts)
                }
                DisclosureGroup("More shortcuts & details") {
                    VStack(spacing: 8) {
                        ForEach(WindowShortcutAction.allCases.filter { ![.left, .right, .maximize, .center].contains($0) }) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                Text(action.shortcut).font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        Text("Letter keys use US key positions. Restore remembers up to 64 windows for this session. App size limits apply; full-screen windows and other Spaces are not supported.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 8)
                }
            }
          }
          DashboardCard {
            Label("Saved layouts", systemImage: DashboardTab.windows.symbol).font(.headline)
            if !module.permitted {
                Text("Accessibility access is required to move, save and restore windows.").font(.caption)
                Button("Grant Accessibility access") { module.requestPermission() }
            } else if !module.ready {
                Text("Waiting for stable displays and display-change confirmation.").font(.caption)
            } else {
                Text("Ready · current desktop only").font(.caption).foregroundStyle(.secondary)
            }

            if setup { HStack(spacing: 8) {
                TextField("New layout name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save layout", action: save)
                    .help("Save current window positions with this name")
                    .disabled(!module.canCapture || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } }
            Divider()
            if module.layouts.isEmpty {
                Text("Arrange your windows, then save a layout to return to it later.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    if layout.id != module.layouts.last?.id { Divider() }
                }
            }
            Text(module.summary).font(.caption).textSelection(.enabled)
          }
           if setup { DashboardCard {
                DisclosureGroup("Automatic restore & exclusions") {
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

/// Reference tiles are informational: clicking Settings must never move a window.
private struct WindowShortcutTile: View {
    let action: WindowShortcutAction
    private var preview: CGRect {
        let display = WindowDisplay(id: "preview", bounds: CGRect(x: 0, y: 0, width: 56, height: 36))
        return action.destination(for: CGRect(x: 14, y: 9, width: 28, height: 18), displays: [display]) ?? display.bounds
    }
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.4))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor))
                    .frame(width: max(1, preview.width - 4), height: max(1, preview.height - 4))
                    .offset(x: preview.minX + 2, y: preview.minY + 2)
            }.frame(width: 56, height: 36).accessibilityHidden(true)
            Text(action.title).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            Text(action.shortcut).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}
