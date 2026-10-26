import SwiftUI

struct LinksSettingsView: View {
    @ObservedObject var module: LinksModule
    @StoredState private var testURL = ""
    @StoredState private var newProfileBrowser = ""
    @StoredState private var newProfileName = ""
    @StoredState private var newProfileFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            defaultBrowser
            if !module.message.isEmpty {
                Label(module.message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            tryLink
            rules
            if !module.profileBrowsers.isEmpty { profiles }
        }.onAppear(perform: module.refresh)
    }

    private var defaultBrowser: some View {
        section {
            HStack(alignment: .top, spacing: 12) {
                AppSymbolBadge(symbol: "arrow.triangle.branch")
                if module.isDefaultBrowser {
                    Label("Better macOS opens your web links", systemImage: "checkmark.circle.fill").font(.headline)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not your default browser yet").font(.headline)
                        Text("Clicked links follow these rules only after Better macOS becomes the default browser.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if !module.isDefaultBrowser { Button("Make default browser", action: module.makeDefaultBrowser).buttonStyle(.borderedProminent) }
            destinationPicker("Everything else opens in", selection: binding(\.fallback))
            if module.destinations.isEmpty { Text("No browsers found. Install a browser, then refresh.").font(.caption).foregroundStyle(.secondary) }
            Button("Refresh browsers", action: module.refresh).controlSize(.small)
        }
    }

    private var rules: some View {
        section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rules").font(.headline)
                    Text("Checked from top to bottom; the first match wins.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { module.update { $0.rules.append(LinkRule(target: $0.fallback)) } } label: { Label("Add rule", systemImage: "plus") }
            }
            if module.config.rules.isEmpty {
                Text("No rules yet. Add one like: Domain github.com/your-team → Chrome · Work.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(binding(\.rules)) { $rule in
                ruleRow($rule)
                if rule.id != module.config.rules.last?.id { Divider() }
            }
        }
    }

    private func ruleRow(_ rule: Binding<LinkRule>) -> some View {
        let value = rule.wrappedValue
        let first = module.config.rules.first?.id == value.id, last = module.config.rules.last?.id == value.id
        let number = (module.config.rules.firstIndex { $0.id == value.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Toggle("Rule \(number)", isOn: rule.enabled).toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Enable rule \(number)")
                Spacer()
                Menu {
                    Button("Move up") { module.update { $0.move(value.id, by: -1) } }.disabled(first)
                    Button("Move down") { module.update { $0.move(value.id, by: 1) } }.disabled(last)
                    Divider()
                    Button("Delete rule", role: .destructive) { module.update { config in config.rules.removeAll { $0.id == value.id } } }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Rule \(number) actions")
            }
            HStack(spacing: 12) {
                Picker("Match", selection: rule.kind) {
                    ForEach(LinkRuleKind.allCases) { Text($0.title).tag($0) }
                }.fixedSize().accessibilityLabel("Rule \(number) match type")
                TextField(value.kind.placeholder, text: rule.pattern).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Rule \(number) match text")
            }
            destinationPicker("Open in", selection: rule.target).accessibilityLabel("Rule \(number) destination")
            if value.domainLooksInvalid {
                Text("Domains don’t take wildcards; switch to Pattern.").font(.caption).foregroundStyle(.orange)
            } else if value.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(value.kind.help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var profiles: some View {
        section {
            Label("Browser profiles", systemImage: "person.crop.circle").font(.headline)
            if let result = module.profileAccessResult { accessResult(result) }
            if module.profilesUnreadable {
                Text("macOS protects your browser’s data from other apps. Allow access to its folder to list profiles automatically, or add them by hand below.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(module.unreadableProfileBrowsers) { browser in
                    Button("Allow access to \(browser.name) profiles…") { module.requestProfileAccess(browser) }
                }
            }
            DisclosureGroup("Available profiles") {
            if !module.foundProfiles.isEmpty {
                Text("Found automatically").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(module.foundProfiles) { profile in
                    profileRow(profile.name, detail: profile.profile ?? "")
                }
            }
            if !module.config.profiles.isEmpty {
                Text("Added by you").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(module.config.profiles) { profile in
                    profileRow("\(module.profileBrowsers.first { $0.id == profile.browser }?.name ?? profile.browser) · \(profile.name)", detail: profile.directory) {
                        Button { module.removeProfile(profile.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove profile").accessibilityLabel("Remove \(profile.name)")
                    }
                }
            }
            if module.foundProfiles.isEmpty && module.config.profiles.isEmpty {
                Text("No profiles listed yet.").font(.caption).foregroundStyle(.secondary)
            }
            }
            DisclosureGroup("Add a profile by hand") { manualProfileForm.padding(.top, 8) }
        }
    }

    @ViewBuilder private func accessResult(_ result: LinkProfileAccessResult) -> some View {
        switch result {
        case .granted(let browser, let count):
            Label(count == 0 ? "Access allowed, but no \(browser) profiles were found." : "Access allowed. Found \(count) \(browser) profile\(count == 1 ? "" : "s"); they’re now in every browser menu.",
                  systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocked(let browser):
            Label("macOS still blocks reading \(browser) profiles. Add them by hand below.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notChosen(let browser):
            Label("Nothing changed. In the picker, select the \(browser) folder and choose Allow.", systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    private func profileRow(_ name: String, detail: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
    }

    private var manualProfileForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 10) {
                if module.profileBrowsers.count > 1 {
                    Picker("Browser", selection: $newProfileBrowser) {
                        ForEach(module.profileBrowsers) { Text($0.name).tag($0.id) }
                    }
                }
                TextField("Name, e.g. Work", text: $newProfileName).textFieldStyle(.roundedBorder).accessibilityLabel("Profile name")
                TextField("Folder, e.g. Profile 1", text: $newProfileFolder).textFieldStyle(.roundedBorder).accessibilityLabel("Profile folder")
                Button("Add profile") {
                    if module.addProfile(browser: selectedProfileBrowser, directory: newProfileFolder, name: newProfileName) {
                        newProfileName = ""; newProfileFolder = ""
                    }
                }.disabled(!LinkDestination.validProfileDirectory(newProfileFolder.trimmingCharacters(in: .whitespaces)))
            }
            Text("Find the folder at chrome://version in that profile: the last part of Profile Path, such as “Profile 1”. The first profile is “Default”.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedProfileBrowser: String {
        module.profileBrowsers.contains { $0.id == newProfileBrowser } ? newProfileBrowser : module.profileBrowsers.first?.id ?? ""
    }

    private var tryLink: some View {
        section {
            Text("Preview a link").font(AppStyle.sectionTitle)
            Text("Paste a link to check its destination. It opens only when you choose Open link.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("https://example.com", text: $testURL).textFieldStyle(.roundedBorder).accessibilityLabel("Link to preview")
                Button("Open link") { module.testOpen(testURL) }.disabled(LinkURL.parse(testURL) == nil)
            }
            if let url = LinkURL.parse(testURL) {
                Label(module.preview(for: url), systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !testURL.isEmpty {
                Text("Enter a full http or https link.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func destinationPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            if !module.destinations.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Unavailable — choose a browser").tag(selection.wrappedValue)
            }
            ForEach(module.destinations) { Text($0.name).tag($0.id) }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<LinkRoutingConfig, Value>) -> Binding<Value> {
        Binding(get: { module.config[keyPath: path] }, set: { value in module.update { $0[keyPath: path] = value } })
    }
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).modifier(AppSurface())
    }
}
