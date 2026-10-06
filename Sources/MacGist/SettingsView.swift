import AppKit
import MacGistCore
import SwiftUI

/// The Settings window (menu → Settings…, ⌘,). Writes straight to
/// `UserDefaults`; the app applies changes as they happen.
struct SettingsView: View {
    @AppStorage(Prefs.Key.lifetimeMinutes) private var lifetime = 15
    @AppStorage(Prefs.Key.inlinePreviewKB) private var inlineKB = 1024
    @AppStorage(Prefs.Key.highlightURL) private var highlightURL = GistPage.defaultHighlightBase
    @AppStorage(Prefs.Key.port) private var port = 8642
    @AppStorage(Prefs.Key.host) private var host = ""
    @AppStorage(Prefs.Key.receive) private var receive = true
    @AppStorage(Prefs.Key.receiveFolder) private var receiveFolder = ""
    @AppStorage(Prefs.Key.maxUploadMB) private var maxUploadMB = 1024
    @AppStorage(Prefs.Key.clipboardLimitKB) private var clipboardKB = 1024
    @AppStorage(Prefs.Key.inboxScope) private var scope = Prefs.Scope.privateNetworks.rawValue

    @State private var interfaces = LocalAddress.interfaces()
    @State private var customHost = ""
    @State private var subnetText = Prefs.subnetEntries.joined(separator: "\n")

    let token: () -> String
    let resetToken: () -> Void

    var body: some View {
        Form {
            Section("Gists") {
                LabeledContent("Lifetime") {
                    HStack {
                        TextField("", value: $lifetime, format: .number).frame(width: 70).multilineTextAlignment(.trailing)
                        Text("minutes")
                        Menu("Presets") {
                            ForEach(Prefs.lifetimePresets, id: \.self) { m in
                                Button(Prefs.describe(minutes: m)) { lifetime = m }
                            }
                        }.fixedSize()
                    }
                }
                note("New gists expire after \(Prefs.describe(minutes: clampedLifetime)). Extend a live one from its menu. 1 minute to 7 days.")
                LabeledContent("Inline preview up to") {
                    HStack { TextField("", value: $inlineKB, format: .number).frame(width: 70).multilineTextAlignment(.trailing); Text("KB") }
                }
                note("Bigger text files get a download card instead of being shown on the page.")
                LabeledContent("Syntax highlighter") {
                    HStack {
                        TextField("", text: $highlightURL, prompt: Text("off"))
                        Button("Default") { highlightURL = GistPage.defaultHighlightBase }
                    }
                }
                note("Base URL of highlight.js, loaded by the viewer's browser. Leave empty for no highlighting (no internet needed).")
            }

            Section("Network") {
                LabeledContent("Port") {
                    TextField("", value: $port, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                }
                if !Prefs.portRange.contains(port) { warn("Use a port from 1024 to 65535.") }
                Picker("Address in links", selection: hostChoice) {
                    Text("Automatic (\(LocalAddress.primaryIPv4() ?? "no network"))").tag("")
                    ForEach(interfaces, id: \.name) { i in
                        Text("\(i.name): \(i.ip)\(i.isPrimary ? " (primary)" : "")").tag("iface:\(i.name)")
                    }
                    if let b = LocalAddress.bonjourName() { Text("Bonjour name (\(b))").tag("bonjour") }
                    Text("Custom…").tag("custom")
                }
                if hostChoice.wrappedValue == "custom" {
                    TextField("Host name or IP", text: $customHost, prompt: Text("mac.example.lan"))
                        .onSubmit { host = customHost }
                        .onChange(of: customHost) { host = $0.isEmpty ? "" : $0 }
                }
                note("Links look like \(previewLink). Automatic follows whatever network you're on.")
            }

            Section("Receiving") {
                Toggle("Receive text and files from the network", isOn: $receive)
                LabeledContent("Save files in") {
                    HStack {
                        Text(Prefs.receiveFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        if !receiveFolder.isEmpty { Button("Default") { receiveFolder = "" } }
                    }
                }
                note("Each sender gets a “From <sender>” folder inside it.")
                LabeledContent("Largest file") {
                    HStack { TextField("", value: $maxUploadMB, format: .number).frame(width: 80).multilineTextAlignment(.trailing); Text("MB") }
                }
                LabeledContent("Largest clipboard text") {
                    HStack { TextField("", value: $clipboardKB, format: .number).frame(width: 80).multilineTextAlignment(.trailing); Text("KB") }
                }
                Picker("Accept senders from", selection: $scope) {
                    Text("Any private network").tag(Prefs.Scope.privateNetworks.rawValue)
                    Text("This Mac's networks only").tag(Prefs.Scope.localNetworks.rawValue)
                    Text("These networks…").tag(Prefs.Scope.custom.rawValue)
                }
                switch Prefs.Scope(rawValue: scope) ?? .privateNetworks {
                case .privateNetworks:
                    note("10.x, 172.16–31.x and 192.168.x: every private network, including other subnets routed to this one. The token is still required.")
                case .localNetworks:
                    note("Right now: \(LocalAddress.localSubnets().map(\.description).joined(separator: ", ")). Follows network changes.")
                case .custom:
                    TextEditor(text: $subnetText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 64)
                        .onChange(of: subnetText) { _ in saveSubnets() }
                    if !badSubnets.isEmpty { warn("Not understood: \(badSubnets.joined(separator: ", ")). Use CIDR, e.g. 192.168.1.0/24.") }
                    note("One per line, e.g. 192.168.0.0/16, 10.1.2.0/24 or a single address. Empty means this Mac's networks.")
                }
                LabeledContent("Inbox token") {
                    HStack {
                        Button("Copy") { copy(token()) }
                        Button("Reset") { resetToken() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 560)
        .onAppear {
            interfaces = LocalAddress.interfaces()
            if !isPreset(host) { customHost = host }
        }
        .onChange(of: scope) { new in
            if new == Prefs.Scope.custom.rawValue { saveSubnets() }
        }
    }

    private var clampedLifetime: Int { min(max(lifetime, Prefs.lifetimeRange.lowerBound), Prefs.lifetimeRange.upperBound) }

    private var previewLink: String {
        "http://\(LocalAddress.linkHost(for: host) ?? "?"):\(port)/g/…"
    }

    private func isPreset(_ h: String) -> Bool { h.isEmpty || h == "bonjour" || h.hasPrefix("iface:") }

    /// Maps the stored `host` onto the picker, with literal hosts shown as "Custom…".
    private var hostChoice: Binding<String> {
        Binding(
            get: { isPreset(host) ? host : "custom" },
            set: { new in
                if new == "custom" { host = customHost.isEmpty ? (LocalAddress.primaryIPv4() ?? "") : customHost; customHost = host }
                else { host = new }
            })
    }

    private var subnetLines: [String] {
        subnetText.split(whereSeparator: { $0.isNewline || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var badSubnets: [String] { subnetLines.filter { Subnet(cidr: $0) == nil } }

    private func saveSubnets() { Prefs.subnetEntries = subnetLines.filter { Subnet(cidr: $0) != nil } }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.receiveFolder
        if panel.runModal() == .OK, let url = panel.url { receiveFolder = url.path }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func warn(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.red)
    }
}
