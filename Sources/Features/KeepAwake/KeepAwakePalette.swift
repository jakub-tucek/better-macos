import AppKit
import SwiftUI

struct KeepAwakePaletteActions {
    enum Action { case start(Int), end, extend, retry, resume, display(Bool) }
    let model: DashboardModel
    var canConfigure: Bool { model.enabledModules.contains(.keepAwake) && !model.stoppingModules.contains(.keepAwake) }
    func perform(_ action: Action) {
        // The bound feature callbacks recheck host admission before owner changes.
        if case .end = action {
            guard model.keepAwakeCanStop || model.keepAwakeProtectionFailed else { return }
            model.onKeepAwakeStop(); return
        }
        guard canConfigure else { return }
        switch action {
        case let .start(minutes): AwakeSessionActions(model: model).start(minutes: minutes)
        case .end: break
        case .extend:
            guard model.keepAwakeRemaining > 0 && model.keepAwakeRemaining < 86400 else { return }
            model.onKeepAwakeExtend()
        case .retry: AwakeSessionActions(model: model).retry()
        case .resume:
            guard model.keepAwakeAppsPaused else { return }
            model.onKeepAwakeResume()
        case let .display(value): model.onKeepDisplayAwakeChanged(value)
        }
    }
}

final class KeepAwakePaletteState: ObservableObject {
    @Published var selection = 0
    func step(_ offset: Int) {
        selection = (selection + offset + AwakeSessionActions.presets.count) % AwakeSessionActions.presets.count
    }
}

final class KeepAwakePaletteController {
    private let presenter = ActionPalettePresenter()
    private var state = KeepAwakePaletteState()
    var isPresented: Bool { presenter.isPresented }

    @discardableResult
    func show(model: DashboardModel, orderFront: Bool = true) -> NSPanel {
        state = KeepAwakePaletteState()
        state.selection = AwakeSessionActions.presets.firstIndex(of: model.keepAwakeMinutes) ?? 0
        let view = KeepAwakePaletteView(model: model, state: state, close: { [weak self] in self?.dismiss() })
        return presenter.show(title: "Keep awake", preferredSize: NSSize(width: 760, height: 600), orderFront: orderFront,
                              handleKey: { [weak self, weak model] event in
            guard let self, let model, self.isPresented,
                  event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty else { return false }
            switch event.keyCode {
            case 123, 126: self.state.step(-1)
            case 124, 125: self.state.step(1)
            case 36, 76, 49: KeepAwakePaletteActions(model: model).perform(.start(AwakeSessionActions.presets[self.state.selection]))
            default: return false
            }
            return true
        }) { view }
    }
    func dismiss() { presenter.dismiss() }
}

struct KeepAwakePaletteView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var state: KeepAwakePaletteState
    let close: () -> Void
    private var actions: KeepAwakePaletteActions { KeepAwakePaletteActions(model: model) }

    var body: some View {
        ActionPaletteLayout(title: "Keep awake", subtitle: AwakeSessionActions(model: model).status,
                            message: "Choose how long your Mac stays awake. Ending a session allows normal sleep; it does not put your Mac to sleep immediately.",
                            leadingHint: "← → choose   ↩ start   esc close", trailingHint: "Tab to other controls", close: close) {
            Image(systemName: model.keepAwakeActive ? "sun.max" : "moon.zzz")
                .font(.system(size: 32, weight: .light)).foregroundStyle(.tint).accessibilityHidden(true)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(Array(AwakeSessionActions.presets.enumerated()), id: \.element) { index, minutes in
                            ActionPaletteTile(title: "\(minutes) minutes", detail: "Start session", selected: state.selection == index,
                                              action: { actions.perform(.start(minutes)) }) {
                                Text("\(minutes)").font(.system(size: 25, weight: .light, design: .rounded)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }.disabled(!actions.canConfigure)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Custom duration").font(.headline)
                        AwakeDurationEditor(model: model, showsStart: true).disabled(!actions.canConfigure)
                    }
                    Divider()
                    DashboardSwitchRow(title: "Keep display awake", isOn: Binding(get: { model.keepDisplayAwake }, set: { actions.perform(.display($0)) }))
                        .disabled(!actions.canConfigure)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Allow sleep").font(.headline)
                            Text("End the session and pause current app rules.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.keepAwakeRemaining > 0 {
                            Button("+15 min") { actions.perform(.extend) }
                                .disabled(!actions.canConfigure || model.keepAwakeRemaining >= 86400)
                        }
                        Button("End session") { actions.perform(.end) }
                            .disabled(!model.keepAwakeCanStop && !model.keepAwakeProtectionFailed)
                    }
                    if model.keepAwakeProtectionFailed {
                        HStack {
                            Label("Protection needs retry", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            Spacer()
                            Button("Retry") { actions.perform(.retry) }.disabled(!actions.canConfigure)
                        }
                    }
                    if !model.keepAwakeAppNames.isEmpty {
                        Text("Requested by: " + model.keepAwakeAppNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    if model.keepAwakeAppsPaused {
                        HStack {
                            Text("App rules paused").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Resume app rules") { actions.perform(.resume) }.disabled(!actions.canConfigure)
                        }
                    }
                    if !model.enabledModules.contains(.keepAwake) {
                        Button("Enable Keep awake in Settings…") { model.onOpenSettings(.system) }
                    }
                }.padding(.vertical, 2)
            }
        }
    }
}
