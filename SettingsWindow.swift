import AppKit

final class SettingsWindow: NSWindowController {
    private let bluetooth: BluetoothModule
    private let spaces: SpacesModule
    var onChange: (() -> Void)?
    private var displayedDevices: [String] = []
    private var displayedLegacyService = false

    init(bluetooth: BluetoothModule, spaces: SpacesModule) {
        self.bluetooth = bluetooth
        self.spaces = spaces
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac Utils Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 400)
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        rebuild()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshIfNeeded() {
        guard window?.isVisible == true else { return }
        if displayedDevices != bluetooth.devices.map({ $0.address + $0.name }) || displayedLegacyService != bluetooth.legacyServicePresent {
            rebuild()
        }
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func checkbox(_ title: String, key: String, value: Bool, enabled: Bool = true) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.state = value ? .on : .off
        button.isEnabled = enabled
        return button
    }

    private func rebuild() {
        displayedDevices = bluetooth.devices.map { $0.address + $0.name }
        displayedLegacyService = bluetooth.legacyServicePresent
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(heading("Bluetooth auto-connect"))
        stack.addArrangedSubview(checkbox("Enable automatic reconnection", key: "enabled", value: bluetooth.autoEnabled,
                                        enabled: bluetooth.available && !bluetooth.legacyServicePresent))
        let info = NSTextField(wrappingLabelWithString: "Select paired devices to reconnect. An intentional disconnect in the menu removes that device from auto-connect.")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        stack.addArrangedSubview(info)
        if bluetooth.devices.isEmpty {
            stack.addArrangedSubview(NSTextField(wrappingLabelWithString: bluetooth.status))
        }
        for device in bluetooth.devices {
            let name = NSTextField(labelWithString: device.name)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let auto = checkbox("Auto", key: "device:" + device.address, value: bluetooth.autoAddresses.contains(device.address))
            auto.toolTip = "Automatically reconnect this device"
            let audio = checkbox("Audio", key: "audio:" + device.address, value: bluetooth.protectedAudioAddresses.contains(device.address))
            audio.toolTip = "Protect this device as audio even before macOS registers its audio output"
            let row = NSStackView(views: [name, auto, audio])
            row.spacing = 10
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        stack.addArrangedSubview(checkbox("Pause while other Bluetooth audio is connected", key: "protectAudio", value: bluetooth.protectOtherAudio))
        stack.addArrangedSubview(checkbox("Use reconnected audio devices as audio output", key: "switchAudio", value: bluetooth.switchAudioOutput))
        if bluetooth.legacyServicePresent {
            let info = NSTextField(wrappingLabelWithString: "Your old Bluetooth LaunchAgent is still running. Take it over to use one reconnect loop. Its scripts and plist will be preserved.")
            info.font = .systemFont(ofSize: 12)
            info.textColor = .secondaryLabelColor
            stack.addArrangedSubview(info)
            let button = NSButton(title: "Take over existing Bluetooth service…", target: self, action: #selector(takeOver))
            button.isEnabled = !bluetooth.isBusy
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(heading("Desktop Spaces"))
        let speed = NSPopUpButton()
        for choice in TransitionSpeed.allCases {
            speed.addItem(withTitle: choice.title)
            speed.lastItem?.tag = choice.rawValue
        }
        speed.selectItem(withTag: spaces.speed.rawValue)
        speed.target = self
        speed.action = #selector(speedChanged(_:))
        stack.addArrangedSubview(speed)
        let note = NSTextField(wrappingLabelWithString: "Instant removes the Space-switching slide. This is strafe’s gesture implementation, not a switch for all macOS animations. Accessibility permission is needed only for this feature.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        window?.contentView = scroll
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        for view in [info, note] {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -44).isActive = true
        }
    }

    @objc private func changed(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let enabled = sender.state == .on
        switch key {
        case "enabled": bluetooth.autoEnabled = enabled
        case "protectAudio": bluetooth.protectOtherAudio = enabled
        case "switchAudio": bluetooth.switchAudioOutput = enabled
        default:
            if key.hasPrefix("device:") {
                let address = String(key.dropFirst("device:".count))
                if enabled { bluetooth.autoAddresses.insert(address) }
                else { bluetooth.autoAddresses.remove(address) }
            } else if key.hasPrefix("audio:") {
                let address = String(key.dropFirst("audio:".count))
                if enabled { bluetooth.protectedAudioAddresses.insert(address) }
                else { bluetooth.protectedAudioAddresses.remove(address) }
            }
        }
        onChange?()
    }

    @objc private func speedChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        spaces.speed = TransitionSpeed.from(rawValue: tag)
        onChange?()
    }

    @objc private func takeOver() {
        let alert = NSAlert()
        alert.messageText = "Move auto-connect into Mac Utils?"
        alert.informativeText = "The old Bluetooth LaunchAgent will be stopped and disabled at login. Its scripts and plist stay intact. Mac Utils will reconnect your selected devices while it is running. Enable Launch at login in the menu if you want this after reboot."
        alert.addButton(withTitle: "Take over")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bluetooth.takeOverLegacyService()
        onChange?()
    }
}
