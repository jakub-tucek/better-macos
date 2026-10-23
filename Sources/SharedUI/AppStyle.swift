import SwiftUI

/// Visual vocabulary shared by Settings, setup, quick actions and action palettes.
enum AppStyle {
    static let radius: CGFloat = 10
    static let spacing: CGFloat = 12
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let title = Font.system(size: 24, weight: .semibold)
}

struct AppSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var selected = false
    func body(content: Content) -> some View {
        content
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: AppStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: AppStyle.radius)
                .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(contrast == .increased ? 0.3 : 0.08)))
    }
}

struct AppSymbolBadge: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .regular))
            .foregroundStyle(.secondary).frame(width: 32, height: 32)
            .modifier(AppSurface()).accessibilityHidden(true)
    }
}

struct AppHeading: View {
    let title: String
    let subtitle: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(compact ? .system(size: 20, weight: .semibold) : AppStyle.title)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(compact ? .caption : .callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A full-width, keyboard-accessible launch row, shared by compact widgets.
struct AppActionRow: View {
    let title: String
    let symbol: String
    var shortcut = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).fontWeight(.medium)
                Spacer(minLength: 4)
                if !shortcut.isEmpty { Text(shortcut).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(10).contentShape(RoundedRectangle(cornerRadius: AppStyle.radius))
                .modifier(AppSurface())
        }.buttonStyle(.plain)
    }
}
