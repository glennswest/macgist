import AppKit
import MacGistCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private enum ServerState { case starting, ready, failed(String) }

    private let store = GistStore()
    private let page = PageSettings()
    private var inbox: Inbox!
    private var received: [Received] = []
    private var statusItem: NSStatusItem!
    private var server: HTTPServer?
    private var runningPort: UInt16?
    private var serverState = ServerState.starting
    private var pendingRestart: DispatchWorkItem?
    private var settingsWindow: NSWindow?
    private var timer: Timer?

    /// Built per share so lifetime and preview-size changes apply immediately.
    private var builder: GistBuilder { GistBuilder(lifetime: Prefs.lifetime, inlineLimit: Prefs.inlinePreviewBytes) }

    private var port: UInt16 { runningPort ?? Prefs.port }

    /// Base URL for links, resolved now (so links follow network changes).
    /// `host` overrides the configured choice (used for "Copy Link via …").
    private func base(host: String? = nil) -> String {
        let h = host ?? LocalAddress.linkHost(for: Prefs.host) ?? ProcessInfo.processInfo.hostName
        return "http://\(h):\(port)"
    }

    private var baseURL: String { base() }

    private func link(_ token: String, host: String? = nil) -> String { "\(base(host: host))/g/\(token)" }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        try? FileManager.default.removeItem(at: GistBuilder.defaultTempRoot)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        inbox = makeInbox()
        applySettings()
        startServer()
        // KVO rather than UserDefaults.didChangeNotification: it also reports
        // changes made outside the app (`defaults write`), not just the Settings window.
        for key in Prefs.Key.all {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for g in store.removeAll() { g.cleanUp() }
        server?.stop()
    }

    /// Launching the app again (Spotlight, Finder, `open -a MacGist`) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// `open -a MacGist file…` also makes a gist.
    func application(_ application: NSApplication, open urls: [URL]) {
        share(files: urls.filter(\.isFileURL))
    }

    // MARK: - Inbox (receive from the network, issue #1)

    private static var tokenFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacGist/inbox-token")
    }

    /// Reads the shared inbox token, creating it (0600) on first run.
    private static func loadToken() -> String {
        if let t = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           t.count >= 16 {
            return t
        }
        return writeNewToken()
    }

    @discardableResult
    private static func writeNewToken() -> String {
        let token = Inbox.makeToken()
        let fm = FileManager.default
        try? fm.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: tokenFile.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return token
    }

    private func makeInbox() -> Inbox {
        Inbox(root: Prefs.receiveFolder, token: Self.loadToken()) { [weak self] item in
            Task { @MainActor in self?.didReceive(item) }
        }
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    /// Pushes current settings into the running inbox/server. Called at launch
    /// and whenever a default changes (Settings window or `defaults write`).
    private func applySettings() {
        inbox.enabled = Prefs.receive
        inbox.root = Prefs.receiveFolder
        inbox.maxFileBytes = Prefs.maxUploadBytes
        inbox.clipboardLimit = Prefs.clipboardLimitBytes
        inbox.subnets = Prefs.subnets
        page.highlightBase = Prefs.highlightURL
        // Port edits arrive keystroke by keystroke; restart once typing settles.
        if let running = runningPort, running != Prefs.port {
            pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.runningPort != Prefs.port else { return }
                    self.startServer()
                }
            }
            pendingRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private var inboxLink: String { "\(baseURL)/in/\(inbox.token)/" }

    private func didReceive(_ item: Received) {
        received.insert(item, at: 0)
        received = Array(received.prefix(5))
        switch item.content {
        case .text(let text, let title):
            copy(text)
            let preview = text.count > 120 ? String(text.prefix(120)) + "…" : text
            notify("Copied from \(item.sender)", title ?? preview)
        case .file(let url):
            notify("Received from \(item.sender)", "\(url.lastPathComponent) (\(HTTP.formatSize(item.size)))", reveal: url)
        }
    }

    private func startServer() {
        server?.stop()
        let port = Prefs.port
        runningPort = port
        serverState = .starting
        do {
            let s = try HTTPServer(port: port, store: store, inbox: inbox, page: page)
            s.start { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.runningPort == port else { return }
                    switch state {
                    case .ready:
                        self.serverState = .ready
                    case .failed(let error):
                        self.serverState = .failed("port \(port): \(error.localizedDescription)")
                        self.notify("MacGist can't serve on port \(port)", error.localizedDescription)
                    }
                }
            }
            server = s
        } catch {
            serverState = .failed("port \(port): \(error.localizedDescription)")
        }
    }

    // MARK: - Services ("Copy to Gist" in the right-click menu)

    /// One service for both contexts: Finder sends file URLs, other apps send
    /// the selected text. Two services with the same title collide, so it's one.
    @objc func copyToGist(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        if !share(from: pboard) {
            error?.pointee = "Nothing to share: select some text or files." as NSString
        }
    }

    /// Files win over text: Finder also puts the file names on the pasteboard as text.
    @discardableResult
    private func share(from pboard: NSPasteboard) -> Bool {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            share(files: urls)
        } else if let text = pboard.string(forType: .string), !text.isEmpty {
            share(text: text)
        } else {
            return false
        }
        return true
    }

    // MARK: - Sharing

    private func share(files: [URL]) {
        guard !files.isEmpty else { return }
        let base = baseURL
        let builder = self.builder
        // Folders get zipped, which can take a while, so build off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try builder.build(files: files, baseURL: base) }
            Task { @MainActor in self.finish(result) }
        }
    }

    private func share(text: String) {
        finish(Result { try builder.build(snippets: [.init(name: "snippet.txt", text: text)], baseURL: baseURL) })
    }

    private func finish(_ result: Result<Gist, Error>) {
        switch result {
        case .success(let gist):
            store.add(gist)
            copy(link(gist.token))
            updateIcon()
            let time = DateFormatter.localizedString(from: gist.expires, dateStyle: .none, timeStyle: .short)
            notify("Gist link copied", "\(gist.title) — expires at \(time)")
        case .failure(let error):
            notify("Couldn't create gist", error.localizedDescription)
        }
    }

    private func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private func purge() {
        let expired = store.purgeExpired()
        for g in expired { g.cleanUp() }
        if !expired.isEmpty { updateIcon() }
    }

    private func updateIcon() {
        let active = !store.active.isEmpty
        let image = NSImage(systemSymbolName: active ? "link.circle.fill" : "link", accessibilityDescription: "MacGist")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        purge()
        menu.removeAllItems()
        let others = LocalAddress.interfaces().filter { $0.ip != LocalAddress.linkHost(for: Prefs.host) }
        switch serverState {
        case .starting: menu.addItem(disabled("Starting…"))
        case .failed(let msg): menu.addItem(disabled("Server failed: \(msg)"))
        case .ready:
            menu.addItem(disabled("Serving on \(baseURL.replacingOccurrences(of: "http://", with: ""))"))
            for i in others { menu.addItem(disabled("    also \(i.ip):\(port) (\(i.name))")) }
        }
        menu.addItem(.separator())

        let gists = store.active
        if gists.isEmpty {
            menu.addItem(disabled("No active gists"))
        } else {
            let now = Date()
            for g in gists {
                let mins = Int(ceil(g.expires.timeIntervalSince(now) / 60))
                let item = NSMenuItem(title: "\(g.title) — \(mins) min left · \(g.hits) hit\(g.hits == 1 ? "" : "s")", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.addItem(action("Copy Link", #selector(copyLink(_:)), g.token))
                for i in others {
                    let via = action("Copy Link via \(i.ip) (\(i.name))", #selector(copyLinkVia(_:)), nil)
                    via.representedObject = [g.token, i.ip]
                    sub.addItem(via)
                }
                sub.addItem(action("Open in Browser", #selector(openGist(_:)), g.token))
                sub.addItem(action("Extend by \(Prefs.describe(minutes: Prefs.lifetimeMinutes))", #selector(extend(_:)), g.token))
                sub.addItem(.separator())
                sub.addItem(action("Revoke", #selector(revoke(_:)), g.token))
                item.submenu = sub
                menu.addItem(item)
            }
            menu.addItem(action("Revoke All", #selector(revokeAll), nil))
        }

        menu.addItem(.separator())
        menu.addItem(action("Copy to Gist from Clipboard", #selector(gistFromClipboard), nil))
        let lifetime = NSMenuItem(title: "Gist Lifetime: \(Prefs.describe(minutes: Prefs.lifetimeMinutes))", action: nil, keyEquivalent: "")
        let lsub = NSMenu()
        var presets = Prefs.lifetimePresets
        if !presets.contains(Prefs.lifetimeMinutes) { presets.append(Prefs.lifetimeMinutes); presets.sort() }
        for m in presets {
            let it = action(Prefs.describe(minutes: m), #selector(setLifetime(_:)), nil)
            it.tag = m
            it.state = m == Prefs.lifetimeMinutes ? .on : .off
            lsub.addItem(it)
        }
        lsub.addItem(.separator())
        lsub.addItem(action("Custom…", #selector(openSettings), nil))
        lifetime.submenu = lsub
        menu.addItem(lifetime)

        menu.addItem(.separator())
        let receive = action("Receive from Network", #selector(toggleReceive), nil)
        receive.state = inbox.enabled ? .on : .off
        menu.addItem(receive)
        if inbox.enabled {
            menu.addItem(action("Copy Send-to-Mac Link", #selector(copyInboxLink), nil))
            menu.addItem(action("Copy Inbox Token", #selector(copyInboxToken), nil))
            menu.addItem(action("Reset Inbox Token", #selector(resetInboxToken), nil))
        }
        for (i, r) in received.enumerated() {
            let title: String
            switch r.content {
            case .text(let t, _): title = "↓ \(r.sender): “\(t.prefix(30).replacingOccurrences(of: "\n", with: " "))\(t.count > 30 ? "…" : "")”"
            case .file(let u): title = "↓ \(r.sender): \(u.lastPathComponent)"
            }
            let item = action(title, #selector(reuseReceived(_:)), nil)
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = action("Settings…", #selector(openSettings), nil)
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let login = action("Open at Login", #selector(toggleLogin), nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacGist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, _ token: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = token
        return item
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, store.lookup(token) != nil else { return }
        copy(link(token))
    }

    @objc private func copyLinkVia(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, store.lookup(pair[0]) != nil else { return }
        copy(link(pair[0], host: pair[1]))
    }

    @objc private func openGist(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, store.lookup(token) != nil,
              let url = URL(string: link(token)) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func extend(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let until = store.extend(token, by: Prefs.lifetime) else { return }
        let time = DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)
        notify("Gist extended", "Now expires at \(time)")
    }

    @objc private func setLifetime(_ sender: NSMenuItem) {
        Prefs.lifetimeMinutes = sender.tag
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(token: { [weak self] in self?.inbox.token ?? "" },
                                    resetToken: { [weak self] in self?.resetInboxToken() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "MacGist Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func revoke(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        store.remove(token)?.cleanUp()
        updateIcon()
    }

    @objc private func revokeAll() {
        for g in store.removeAll() { g.cleanUp() }
        updateIcon()
    }

    @objc private func gistFromClipboard() {
        if !share(from: .general) {
            notify("Clipboard is empty", "Copy some text or files first.")
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("Couldn't change login item", error.localizedDescription)
        }
    }

    @objc private func toggleReceive() {
        Prefs.receive.toggle()
    }

    @objc private func copyInboxLink() { copy(inboxLink) }

    @objc private func copyInboxToken() { copy(inbox.token) }

    @objc private func resetInboxToken() {
        inbox.token = Self.writeNewToken()
        notify("Inbox token reset", "Senders need the new token (it's on the clipboard).")
        copy(inbox.token)
    }

    /// Text: copy it again. File: show it in Finder.
    @objc private func reuseReceived(_ sender: NSMenuItem) {
        guard received.indices.contains(sender.tag) else { return }
        switch received[sender.tag].content {
        case .text(let t, _): copy(t)
        case .file(let u): NSWorkspace.shared.activateFileViewerSelecting([u])
        }
    }

    // MARK: - Notifications

    private func notify(_ title: String, _ body: String, reveal: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let reveal { content.userInfo = ["reveal": reveal.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    /// Clicking a "Received" notification shows the file in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["reveal"] as? String {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        completionHandler()
    }
}
