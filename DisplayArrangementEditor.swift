import SwiftUI

struct DisplayArrangementEditor: View {
    let original: [DisplayPosition]
    let monitors: [Monitor]
    let mainUUID: String
    let onApply: (DisplayArrangementRequest) -> Void
    let onCancel: () -> Void
    @StoredState private var draft: [DisplayPosition]
    @StoredState private var dragging: String?
    @StoredState private var translation = CGSize.zero

    init(original: [DisplayPosition], monitors: [Monitor], mainUUID: String,
         onApply: @escaping (DisplayArrangementRequest) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.monitors = monitors
        self.mainUUID = mainUUID
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: original)
    }

    private var viewport: CGRect {
        (original + draft).reduce(CGRect.null) { result, position in
            result.union(CGRect(x: Int(position.x), y: Int(position.y), width: Int(position.width ?? 0), height: Int(position.height ?? 0)))
        }.insetBy(dx: -800, dy: -1000)
    }

    private var normalized: [DisplayPosition]? { DisplayTopology.normalized(draft, anchor: mainUUID) }
    private var valid: Bool { DisplayTopology.isValidArrangement(draft) }
    private var changed: Bool { normalized?.sorted(by: { $0.uuid < $1.uuid }) != original.sorted(by: { $0.uuid < $1.uuid }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Arrange displays").font(.title2).bold()
            Text("Drag to arrange. Edges snap.")
                .font(.callout).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / viewport.width, geometry.size.height / viewport.height)
                let left = (geometry.size.width - viewport.width * scale) / 2
                let top = (geometry.size.height - viewport.height * scale) / 2
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .controlBackgroundColor)
                    ForEach(draft, id: \.uuid) { position in
                        let monitor = monitors.first { $0.uuid == position.uuid }
                        let delta = dragging == position.uuid ? translation : .zero
                        VStack(spacing: 5) {
                            Image(systemName: monitor?.isBuiltIn == true ? "laptopcomputer" : "display")
                            Text(monitor?.name ?? "Display").font(.caption).multilineTextAlignment(.center).lineLimit(2)
                            if position.uuid == mainUUID { Text("Main").font(.caption2).bold() }
                        }
                        .frame(width: max(1, CGFloat(position.width ?? 0) * scale - 2),
                               height: max(1, CGFloat(position.height ?? 0) * scale - 2))
                        .background(dragging == position.uuid ? Color.blue.opacity(0.3) : Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 2))
                        .contentShape(Rectangle())
                        .offset(x: left + (CGFloat(position.x) - viewport.minX) * scale + delta.width,
                                y: top + (CGFloat(position.y) - viewport.minY) * scale + delta.height)
                        .zIndex(dragging == position.uuid ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { value in dragging = position.uuid; translation = value.translation }
                            .onEnded { value in
                                let origin = CGPoint(x: CGFloat(position.x) + value.translation.width / scale,
                                                     y: CGFloat(position.y) + value.translation.height / scale)
                                if let moved = DisplayTopology.snapped(draft, moving: position.uuid, to: origin) { draft = moved }
                                dragging = nil
                                translation = .zero
                            })
                        .help("Drag \(monitor?.name ?? "display") to arrange")
                    }
                }.clipped()
            }.frame(minHeight: 260)
            Text(valid ? "Reverts after 20 seconds unless confirmed." :
                 "Join all screens along an edge to apply.")
                .font(.caption).foregroundStyle(valid ? Color.secondary : Color.orange)
            HStack {
                Button("Reset preview") { draft = original }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply layout") {
                    if let normalized { onApply(DisplayArrangementRequest(original: original, desired: normalized, mainUUID: mainUUID)) }
                }.buttonStyle(.borderedProminent).disabled(!valid || !changed || dragging != nil)
            }
        }.padding(20).frame(minWidth: 640, minHeight: 440)
    }
}
