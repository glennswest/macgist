import Foundation

/// Page options the UI can change while the server runs.
public final class PageSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var _highlightBase = GistPage.defaultHighlightBase

    public init() {}

    /// Base URL of highlight.js (`…/highlight.min.js` and `…/styles/` under it). Empty = off.
    public var highlightBase: String {
        get { lock.withLock { _highlightBase } }
        set { lock.withLock { _highlightBase = newValue } }
    }
}

/// Renders the HTML page for a gist, and the plain-text listing that
/// non-browser clients (curl, wget) get for multi-file gists.
public enum GistPage {
    /// Default highlight.js location (fetched by the viewer's browser). Empty = no highlighting.
    public static let defaultHighlightBase = "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0"

    public static func entryPath(_ gist: Gist, _ index: Int, download: Bool) -> String {
        "/g/\(gist.token)/\(download ? "dl" : "raw")/\(index)/\(HTTP.encodePathSegment(gist.entries[index].name))"
    }

    public static func archivePath(_ gist: Gist) -> String {
        "/g/\(gist.token)/zip/\(HTTP.encodePathSegment(GistBuilder.archiveName(for: gist)))"
    }

    public static func listing(_ gist: Gist, base: String) -> String {
        var out = "\(gist.title)\n\n"
        for i in gist.entries.indices {
            out += "\(base)\(entryPath(gist, i, download: false))\n"
        }
        out += "\nall: \(base)\(archivePath(gist))\n"
        return out
    }

    public static func notFound() -> String {
        page(title: "Gist expired", head: "", body: """
            <main class="gone"><h1>This gist has expired</h1>
            <p>Gist links are temporary. Ask for a new one.</p></main>
            """)
    }

    public static func render(_ gist: Gist, sharedBy: String, highlightBase: String = defaultHighlightBase,
                              now: Date = Date()) -> String {
        let esc = HTTP.escapeHTML
        let remaining = max(0, Int(gist.expires.timeIntervalSince(now)))
        var cards = ""
        for (i, e) in gist.entries.enumerated() {
            let raw = entryPath(gist, i, download: false)
            let dl = entryPath(gist, i, download: true)
            let ext = esc((e.name as NSString).pathExtension.lowercased())
            var body: String
            var copy = ""
            switch e.kind {
            case .text:
                let text = (try? String(contentsOf: e.fileURL, encoding: .utf8))
                    ?? (try? String(contentsOf: e.fileURL, encoding: .isoLatin1)) ?? ""
                body = "<pre><code data-ext=\"\(ext)\">\(esc(text))</code></pre>"
                copy = "<button type=\"button\" class=\"copy\" data-copy=\"code-\(i)\">Copy</button>"
                body = body.replacingOccurrences(of: "<code ", with: "<code id=\"code-\(i)\" ")
            case .image:
                body = "<div class=\"img\"><img src=\"\(raw)\" alt=\"\(esc(e.name))\" loading=\"lazy\"></div>"
            case .binary:
                body = "<div class=\"bin\"><span>\(esc(e.mime))</span><a class=\"btn primary\" href=\"\(dl)\">Download \(esc(e.name))</a></div>"
            }
            cards += """
                <section class="file">
                  <header><span class="name">\(esc(e.name))</span><span class="size">\(HTTP.formatSize(e.size))</span>
                    <span class="actions">\(copy)<a class="btn" href="\(raw)">Raw</a><a class="btn" href="\(dl)">Download</a></span></header>
                  \(body)
                </section>

                """
        }

        let count = gist.entries.count
        let summary = "\(count) file\(count == 1 ? "" : "s") · \(HTTP.formatSize(gist.totalSize))"
        let hljs = esc(highlightBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
        let head = hljs.isEmpty ? "" : """
            <link rel="stylesheet" href="\(hljs)/styles/github.min.css" media="(prefers-color-scheme: light)">
            <link rel="stylesheet" href="\(hljs)/styles/github-dark.min.css" media="(prefers-color-scheme: dark)">
            <script defer src="\(hljs)/highlight.min.js"></script>
            """
        let body = """
            <main>
              <div class="top">
                <div><h1>\(esc(gist.title))</h1>
                  <p class="meta">\(summary) · from \(esc(sharedBy)) · <span id="left" data-left="\(remaining)"></span></p></div>
                <a class="btn primary" href="\(archivePath(gist))">Download all (.zip)</a>
              </div>
            \(cards)</main>
            <script>
            (function () {
              var el = document.getElementById('left'), left = +el.dataset.left, end = Date.now() + left * 1000;
              function tick() {
                var s = Math.max(0, Math.round((end - Date.now()) / 1000));
                el.textContent = s ? 'expires in ' + Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0') : 'expired';
                if (!s) { document.body.classList.add('expired'); return; }
                setTimeout(tick, 1000);
              }
              tick();
              document.addEventListener('click', function (ev) {
                var b = ev.target.closest('[data-copy]'); if (!b) return;
                var text = document.getElementById(b.dataset.copy).textContent;
                var done = function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); };
                // Plain http on the LAN is not a secure context, so navigator.clipboard is often missing.
                if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(done); return; }
                var ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
                document.body.appendChild(ta); ta.select(); try { document.execCommand('copy'); done(); } catch (e) {} ta.remove();
              });
              window.addEventListener('load', function () {
                if (!window.hljs) return;
                document.querySelectorAll('code[data-ext]').forEach(function (c) {
                  var ext = c.dataset.ext, alias = { h: 'c', hpp: 'cpp', zsh: 'bash', sh: 'bash', yml: 'yaml', tf: 'hcl' }[ext] || ext;
                  if (alias && hljs.getLanguage(alias)) { c.classList.add('language-' + alias); hljs.highlightElement(c); }
                });
              });
            })();
            </script>
            """
        return page(title: gist.title, head: head, body: body)
    }

    /// "Send to this Mac" page at `/in/<token>/`: text goes to the Mac's
    /// clipboard, files to its Downloads. Uses absolute `/in/<token>/` URLs so it
    /// works with or without the trailing slash.
    public static func inboxPage(token: String, macName: String) -> String {
        let esc = HTTP.escapeHTML
        let body = """
            <main>
              <div class="top"><div><h1>Send to \(esc(macName))</h1>
                <p class="meta">Text goes to its clipboard; files go to its Downloads.</p></div></div>
              <section class="file">
                <header><span class="name">Text → clipboard</span></header>
                <textarea id="text" spellcheck="false" placeholder="Paste or type here"></textarea>
              </section>
              <section class="file">
                <header><span class="name">Files → Downloads</span></header>
                <label id="drop" class="drop"><input id="files" type="file" multiple hidden>
                  <span id="droptext">Drop files here or click to choose</span></label>
              </section>
              <div class="sendrow"><button id="send" class="btn primary" type="button">Send</button><span id="status" class="meta"></span></div>
            </main>
            <script>
            (function () {
              var base = '/in/\(token)/', picked = [];
              var text = document.getElementById('text'), input = document.getElementById('files'),
                  drop = document.getElementById('drop'), status = document.getElementById('status'),
                  send = document.getElementById('send'), droptext = document.getElementById('droptext');
              function show() {
                droptext.textContent = picked.length ? picked.map(function (f) { return f.name; }).join(', ')
                  : 'Drop files here or click to choose';
              }
              input.addEventListener('change', function () { picked = Array.from(input.files); show(); });
              ['dragenter', 'dragover'].forEach(function (t) { drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.add('over'); }); });
              ['dragleave', 'drop'].forEach(function (t) { drop.addEventListener(t, function (e) { e.preventDefault(); drop.classList.remove('over'); }); });
              drop.addEventListener('drop', function (e) { picked = picked.concat(Array.from(e.dataTransfer.files)); show(); });
              function put(method, url, body, label) {
                return new Promise(function (ok, bad) {
                  var x = new XMLHttpRequest();
                  x.open(method, url);
                  x.upload.onprogress = function (e) {
                    if (e.lengthComputable) status.textContent = label + ' ' + Math.round(100 * e.loaded / e.total) + '%';
                  };
                  x.onload = function () { x.status < 300 ? ok() : bad(new Error(label + ': ' + x.status + ' ' + x.responseText.trim())); };
                  x.onerror = function () { bad(new Error(label + ': network error')); };
                  x.send(body);
                });
              }
              send.addEventListener('click', function () {
                if (!text.value && !picked.length) { status.textContent = 'Nothing to send.'; return; }
                send.disabled = true;
                var steps = Promise.resolve(), n = 0;
                picked.forEach(function (f) {
                  steps = steps.then(function () { return put('PUT', base + encodeURIComponent(f.name), f, f.name).then(function () { n++; }); });
                });
                if (text.value) {
                  steps = steps.then(function () {
                    return put('POST', base + 'clipboard', new Blob([text.value], { type: 'text/plain;charset=utf-8' }), 'text');
                  });
                }
                steps.then(function () {
                  status.textContent = 'Sent' + (n ? ' ' + n + ' file' + (n === 1 ? '' : 's') : '') + (text.value ? (n ? ' and text' : ' text') + ' (on the clipboard)' : '') + '.';
                  text.value = ''; picked = []; input.value = ''; show();
                }).catch(function (e) { status.textContent = e.message; })
                  .then(function () { send.disabled = false; });
              });
            })();
            </script>
            """
        return page(title: "Send to \(macName)", head: "", body: body)
    }

    static func page(title: String, head: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>\(HTTP.escapeHTML(title))</title>
        \(head)
        <style>
        :root { --bg: #f6f7f9; --card: #fff; --line: #d9dde3; --text: #1d2228; --muted: #5d6673; --accent: #2f6fde; --bar: #f0f2f5; }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #0f1216; --card: #161a20; --line: #2a3038; --text: #e3e7ec; --muted: #8b95a3; --accent: #6ea2ff; --bar: #1c2129; }
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        main { max-width: 980px; margin: 0 auto; padding: 28px 16px 64px; }
        .top { display: flex; gap: 16px; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; margin-bottom: 20px; }
        h1 { font-size: 22px; margin: 0 0 4px; word-break: break-word; }
        .meta { margin: 0; color: var(--muted); font-size: 13px; }
        .file { background: var(--card); border: 1px solid var(--line); border-radius: 8px; margin-bottom: 18px; overflow: hidden; }
        .file header { display: flex; align-items: center; gap: 10px; padding: 8px 12px; background: var(--bar); border-bottom: 1px solid var(--line); flex-wrap: wrap; }
        .name { font: 600 13px ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
        .size { color: var(--muted); font-size: 12px; }
        .actions { margin-left: auto; display: flex; gap: 6px; }
        .btn, .copy { display: inline-block; padding: 4px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--card);
          color: var(--text); font: 500 12px/1.4 inherit; text-decoration: none; cursor: pointer; }
        .btn:hover, .copy:hover { border-color: var(--accent); }
        .btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; padding: 6px 14px; font-size: 13px; }
        pre { margin: 0; overflow-x: auto; }
        pre code, pre code.hljs { display: block; padding: 14px 16px; font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; background: transparent; white-space: pre; tab-size: 4; }
        .img { padding: 16px; text-align: center; }
        .img img { max-width: 100%; height: auto; }
        .bin { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 18px 16px; color: var(--muted); font-size: 13px; flex-wrap: wrap; }
        textarea { display: block; width: 100%; min-height: 180px; border: 0; padding: 14px 16px; resize: vertical;
          background: transparent; color: var(--text); font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
        textarea:focus { outline: none; }
        .drop { display: block; margin: 14px; padding: 28px 16px; border: 2px dashed var(--line); border-radius: 8px;
          text-align: center; color: var(--muted); cursor: pointer; word-break: break-word; }
        .drop.over { border-color: var(--accent); color: var(--text); }
        .sendrow { display: flex; align-items: center; gap: 14px; }
        .btn:disabled { opacity: .5; cursor: default; }
        body.expired main { opacity: .45; pointer-events: none; }
        .gone { text-align: center; padding-top: 18vh; }
        .gone p { color: var(--muted); }
        </style></head>
        <body>
        \(body)
        </body></html>
        """
    }
}
