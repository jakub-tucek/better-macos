import AppKit

/// Native controls inside a menu row: display details left, on/off switch right.
final class MonitorRow: NSView {
    let toggle = NSSwitch()

    init(monitor: Monitor, canToggle: Bool, target: AnyObject, action: Selector) {
        let symbol = monitor.id.map { CGDisplayIsBuiltin($0) != 0 } == true ? "laptopcomputer" : "display"
        let detail: String
        if monitor.id == nil { detail = "Unavailable" }
        else if monitor.isMain { detail = "Main display" }
        else { detail = monitor.enabled ? "On" : "Off" }
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 48))
        configure(title: monitor.name, subtitle: detail, symbol: symbol, isOn: monitor.enabled,
                  canToggle: canToggle, identifier: monitor.uuid, target: target, action: action)
    }

    init(title: String, subtitle: String, symbol: String, isOn: Bool, canToggle: Bool,
         identifier: String, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 48))
        configure(title: title, subtitle: subtitle, symbol: symbol, isOn: isOn, canToggle: canToggle,
                  identifier: identifier, target: target, action: action)
    }

    private func configure(title: String, subtitle detail: String, symbol: String, isOn: Bool,
                           canToggle: Bool, identifier: String, target: AnyObject, action: Selector) {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = isOn ? .labelColor : .secondaryLabelColor
        icon.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [name, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        toggle.state = isOn ? .on : .off
        toggle.controlSize = .small
        toggle.isEnabled = canToggle
        toggle.identifier = NSUserInterfaceItemIdentifier(identifier)
        toggle.target = target
        toggle.action = action
        toggle.setAccessibilityLabel("\(title) enabled")
        toggle.toolTip = canToggle ? "Turn \(title) \(isOn ? "off" : "on")" : "Currently unavailable"

        for view in [icon, labels, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 20),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -14),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
