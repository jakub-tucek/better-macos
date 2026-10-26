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
            section { LinkRulesEditor(module: module) }
            tryLink
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
            destinationPicker("Everything else opens in", selection: Binding(get: { module.config.fallback }, set: { target in module.update { $0.fallback = target } }))
            if module.destinations.isEmpty { Text("No browsers found. Install a browser, then refresh.").font(.caption).foregroundStyle(.secondary) }
            Button("Refresh browsers", action: module.refresh).controlSize(.small)
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
                    ForEach(module.foundProfiles) { profile in profileRow(profile.name, detail: profile.profile ?? "") }
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
                if module.foundProfiles.isEmpty && module.config.profiles.isEmpty { Text("No profiles listed yet.").font(.caption).foregroundStyle(.secondary) }
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
        VStack(alignment: .leading, spacing: 10) {
            if module.profileBrowsers.count > 1 {
                Picker("Browser", selection: $newProfileBrowser) { ForEach(module.profileBrowsers) { Text($0.name).tag($0.id) } }
            }
            TextField("Name, e.g. Work", text: $newProfileName).textFieldStyle(.roundedBorder).accessibilityLabel("Profile name")
            TextField("Folder, e.g. Profile 1", text: $newProfileFolder).textFieldStyle(.roundedBorder).accessibilityLabel("Profile folder")
            Button("Add profile") {
                if module.addProfile(browser: selectedProfileBrowser, directory: newProfileFolder, name: newProfileName) {
                    newProfileName = ""; newProfileFolder = ""
                }
            }.disabled(!LinkDestination.validProfileDirectory(newProfileFolder.trimmingCharacters(in: .whitespaces)))
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
                Label(module.preview(for: url), systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
            } else if !testURL.isEmpty { Text("Enter a full http or https link.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func destinationPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            if !module.destinations.contains(where: { $0.id == selection.wrappedValue }) { Text("Unavailable — choose a browser").tag(selection.wrappedValue) }
            ForEach(module.destinations) { Text($0.name).tag($0.id) }
        }
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppStyle.spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).modifier(AppSurface())
    }
}
