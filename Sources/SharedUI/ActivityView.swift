import AppKit
import SwiftUI

/// Observed only by the activity window, not by every Dashboard consumer.
final class ActivityPresentation: ObservableObject {
    @Published private(set) var entries: [ActivityEntry]
    let journal: ActivityJournal

    init(journal: ActivityJournal) {
        self.journal = journal; entries = journal.entries
        journal.onChange = { [weak self] in
            guard let self else { return }
            entries = self.journal.entries
        }
    }
}

struct ActivityView: View {
    @ObservedObject var presentation: ActivityPresentation
    @StoredState private var expanded: Set<ActivityOperationID> = []
    @StoredState private var readingHistory = false
    @StoredState private var hasNewEntries = false
    @StoredState private var visibleEntry: ActivityOperationID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear activity") { presentation.journal.clear(); expanded.removeAll() }
                    .disabled(presentation.entries.isEmpty)
            }
            Text("Recent activity from this app session. Cleared when the app quits. Keeps the latest 300 entries.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                Button(hasNewEntries ? "Show latest activity" : "Show latest") {
                    proxy.scrollTo("latest", anchor: .top); readingHistory = false; hasNewEntries = false
                }.opacity(readingHistory ? 1 : 0).disabled(!readingHistory).accessibilityHidden(!readingHistory)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(height: 1).id("latest")
                        if presentation.entries.isEmpty { Text("No activity recorded yet this session.").foregroundStyle(.secondary) }
                        ForEach(presentation.entries) { entry in
                            ActivityRow(entry: entry, expanded: Binding(get: { expanded.contains(entry.id) }, set: {
                                if $0 { expanded.insert(entry.id) } else { expanded.remove(entry.id) }
                            })).id(entry.id)
                            Divider()
                        }
                    }.scrollTargetLayout().padding(4)
                }
                .scrollPosition(id: $visibleEntry, anchor: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in geometry.contentOffset.y > 24 } action: { _, away in
                    readingHistory = away
                    if !away { hasNewEntries = false }
                }
                .onChange(of: presentation.entries.first?.id) { _, _ in
                    expanded.formIntersection(presentation.entries.map(\.id))
                    if presentation.entries.isEmpty { readingHistory = false; hasNewEntries = false; visibleEntry = nil }
                    else if readingHistory { hasNewEntries = true }
                    else { proxy.scrollTo("latest", anchor: .top) }
                }
            }
        }.padding(24).frame(minWidth: 540, minHeight: 360)
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(entry.details).textSelection(.enabled).padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.startedAt, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .accessibilityLabel(entry.startedAt.formatted(date: .complete, time: .complete))
                    Text("\(entry.event.feature) · \(entry.trigger.rawValue)").foregroundStyle(.secondary)
                }.font(.caption)
                Text(entry.event.title).textSelection(.enabled)
                Text(entry.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
