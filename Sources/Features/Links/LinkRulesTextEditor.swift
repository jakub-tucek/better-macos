import SwiftUI

struct LinkRulesTextEditor: View {
    @ObservedObject var module: LinksModule
    @StoredState private var text = ""
    @StoredState private var baseline: [LinkRule] = []
    @StoredState private var loaded = false
    @StoredState private var saveFailed = false

    private var changed: Bool { text != LinkRuleText.render(baseline) }
    private var conflict: Bool { module.config.rules != baseline }

    var body: some View {
        let parsed = LinkRuleText.parse(text, destinations: module.destinations, existing: baseline)
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules").font(.headline)
            Text("One rule per line: match -> browser or profile. Checked top to bottom; first match wins.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 220, maxHeight: 340)
                .autocorrectionDisabled(true)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
                .accessibilityLabel("Routing rules, one per line")
            Text("github.com/your-team -> Safari\npattern: *.example.com/* -> com.google.Chrome\noff: contains: project=work -> Safari")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Domain matching is the default. Use pattern: for wildcards, contains: for text anywhere, and off: to disable a rule. Delete its line to remove it; blank text removes all rules. Changes apply only when saved.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if conflict {
                Label("Rules changed elsewhere. Reload before saving.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(Array(parsed.errors.enumerated()), id: \.offset) { _, message in
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if saveFailed { Text("Could not save. Check app status, then retry.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Save rules") {
                    if module.saveRuleText(text, expected: baseline) { reload() }
                    else { saveFailed = true }
                }.buttonStyle(.borderedProminent).disabled(!changed || conflict || !parsed.errors.isEmpty)
                Button(conflict ? "Reload rules" : "Discard changes", action: reload).disabled(!changed && !conflict)
                Text("\(parsed.rules.count) rules").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Browser and profile IDs") {
                ForEach(module.destinations) { destination in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.name).font(.caption.weight(.semibold))
                        Text(destination.id).font(.caption.monospaced()).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                }
            }
        }
        .onAppear { if !loaded { reload(); loaded = true } }
        .onChange(of: module.config.rules) { _, _ in if !changed { reload() } }
    }

    private func reload() { baseline = module.config.rules; text = LinkRuleText.render(baseline); saveFailed = false }
}
