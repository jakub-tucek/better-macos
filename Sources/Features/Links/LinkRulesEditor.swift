import SwiftUI

struct LinkRulesEditor: View {
    @ObservedObject var module: LinksModule
    @StoredState private var draft = LinkRulesDraft()
    @StoredState private var loaded = false
    @StoredState private var saveFailed = false

    init(module: LinksModule, initialMode: LinkRulesDraft.Mode = .visual) {
        self.module = module
        _draft = StoredState(initialValue: LinkRulesDraft(mode: initialMode))
    }

    private var conflict: Bool { module.config.rules != draft.baseline }

    var body: some View {
        let parsed = draft.parsed(destinations: module.destinations)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Picker("Rule editor", selection: Binding(get: { draft.mode }, set: { draft.select($0, destinations: module.destinations) })) {
                    ForEach(LinkRulesDraft.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 180)
            }
            if draft.mode == .visual { visualRules }
            else {
            Text("One rule per line: match -> browser or profile. Checked top to bottom; first match wins.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.text).font(.body.monospaced()).frame(minHeight: 220, maxHeight: 340)
                .autocorrectionDisabled(true)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)))
                .accessibilityLabel("Routing rules, one per line")
            Text("github.com/your-team -> Safari\npattern: *.example.com/* -> com.google.Chrome\noff: contains: project=work -> Safari")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Domain matching is the default. Use pattern: for wildcards, contains: for text anywhere, and off: to disable a rule. Delete its line to remove it; blank text removes all rules. Changes apply only when saved.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if conflict {
                Label("Rules changed elsewhere. Reload before saving.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(Array(parsed.errors.enumerated()), id: \.offset) { _, message in
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if saveFailed { Text("Could not save. Check app status, then retry.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Save rules") {
                    if module.saveRuleText(draft.text, expected: draft.baseline) { reload() }
                    else { saveFailed = true }
                }.buttonStyle(.borderedProminent).disabled(!draft.changed || conflict || !parsed.errors.isEmpty)
                Button(conflict ? "Reload rules" : "Discard changes", action: reload).disabled(!draft.changed && !conflict)
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
        .onChange(of: module.config.rules) { _, _ in if !draft.changed { reload() } }
    }

    private var visualRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checked top to bottom; first match wins. Changes apply only when saved.").font(.caption).foregroundStyle(.secondary)
            if draft.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
            ForEach(Array(draft.rules.enumerated()), id: \.element.id) { index, rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Rule \(index + 1)", isOn: ruleBinding(rule, \.enabled)).toggleStyle(.switch).controlSize(.small)
                        Spacer()
                        Button { move(rule.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).accessibilityLabel("Move rule \(index + 1) up")
                        Button { move(rule.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == draft.rules.count - 1).accessibilityLabel("Move rule \(index + 1) down")
                        Button(role: .destructive) { draft.edit { $0.removeAll { $0.id == rule.id } } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete rule \(index + 1)")
                    }
                    HStack {
                        Picker("Match", selection: ruleBinding(rule, \.kind)) {
                            ForEach(LinkRuleKind.allCases) { Text($0.title).tag($0) }
                        }.fixedSize()
                        TextField(rule.kind.placeholder, text: ruleBinding(rule, \.pattern))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Rule \(index + 1) match text")
                    }
                    Picker("Open in", selection: ruleBinding(rule, \.target)) {
                        if !module.destinations.contains(where: { $0.id == rule.target }) { Text("Unavailable: \(rule.target)").tag(rule.target) }
                        ForEach(module.destinations) { Text($0.name).tag($0.id) }
                    }.accessibilityLabel("Rule \(index + 1) destination")
                    if rule.domainLooksInvalid { Text("Domains do not take wildcards; choose Pattern.").font(.caption).foregroundStyle(.orange) }
                    if rule.id != draft.rules.last?.id { Divider() }
                }
            }
            Button { draft.edit { $0.append(LinkRule(target: module.config.fallback)) } } label: { Label("Add rule", systemImage: "plus") }
        }
    }

    private func ruleBinding<Value>(_ snapshot: LinkRule, _ path: WritableKeyPath<LinkRule, Value>) -> Binding<Value> {
        let id = snapshot.id
        return Binding(get: { (draft.rules.first { $0.id == id } ?? snapshot)[keyPath: path] }, set: { value in
            draft.edit { rules in if let index = rules.firstIndex(where: { $0.id == id }) { rules[index][keyPath: path] = value } }
        })
    }

    private func move(_ id: UUID, by offset: Int) {
        draft.edit { rules in
            guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return }
            rules.swapAt(index, index + offset)
        }
    }

    private func reload() { draft.load(module.config.rules); saveFailed = false }
}
