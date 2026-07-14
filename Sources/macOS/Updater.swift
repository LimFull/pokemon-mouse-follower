import AppKit

// MARK: - Self-update

/// Checks the latest GitHub release and, on request, downloads the notarized
/// .dmg and swaps the running .app bundle in place, then relaunches.
///
/// No Sparkle / third-party dependency: the release pipeline (`release.sh`)
/// already publishes a stable, notarized `PokemonMouseFollower.dmg` on every
/// GitHub release, so the whole flow is a version check + dmg download + copy.
enum Updater {
    static let owner = "LimFull"
    static let repo  = "pokemon-mouse-follower"

    /// GitHub API endpoint listing recent releases, newest first. The single
    /// `/releases/latest` may be a Windows-only release with no .dmg, so the
    /// check scans for the newest release that actually ships one.
    private static var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!
    }
    /// Versionless asset every release publishes — used if the API lookup can't
    /// pin the exact `.dmg` asset URL.
    private static var fallbackDMG: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/PokemonMouseFollower.dmg")!
    }
    /// The app name inside the disk image (volume root), fixed by `release.sh`.
    private static let dmgAppName = "PokemonMouseFollower.app"
    /// Versionless stable dmg every macOS release publishes (release.sh).
    private static let stableDMGName = "PokemonMouseFollower.dmg"
    /// Releases Atom feed — a normal github.com page, NOT the rate-limited API.
    private static var atomURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases.atom")!
    }
    /// Conventional download URL for a tag's stable dmg. release.sh uploads it
    /// on every macOS release, so we can offer an update without asking the API
    /// to resolve the asset URL — and a HEAD on it tells us whether a given tag
    /// actually ships a macOS build (vs. a Windows-only release).
    private static func releaseDownloadURL(tag: String) -> URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(stableDMGName)")!
    }

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    struct Release {
        let version: String   // normalized, e.g. "1.4.0" (leading "v" stripped)
        let dmgURL: URL
        let notes: String
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Updater", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    // MARK: Version comparison

    /// "v1.4.0" -> [1, 4, 0]; non-numeric junk in a component drops to 0.
    private static func components(_ v: String) -> [Int] {
        v.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
         .split(separator: ".")
         .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// True iff `latest` is a strictly higher version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = components(latest), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Fetch latest release (completion always on the main thread)

    /// Version check goes through the releases **Atom feed** first, not the
    /// GitHub API. The API's unauthenticated limit is only 60 requests/hour per
    /// IP, so repeated "check for updates" clicks (or a shared/NAT'd IP) hit
    /// HTTP 403 — which used to surface as a bare "서버 응답 오류". The feed is a
    /// normal github.com page with far more generous limits, so routine checks
    /// (the common "already up to date" case) cost zero API calls. The API is
    /// kept as a fallback for when the feed is unreachable or its format changes.
    static func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        fetchViaAtom { result in
            switch result {
            case .success(let release): DispatchQueue.main.async { completion(.success(release)) }
            case .failure: fetchViaAPI(completion: completion)   // feed down → API fallback
            }
        }
    }

    // MARK: Atom feed (primary — no API rate limit)

    private static func fetchViaAtom(completion: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: atomURL, timeoutInterval: 15)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            guard error == nil,
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let xml = String(data: data, encoding: .utf8) else {
                completion(.failure(err("atom feed unavailable"))); return   // → API fallback
            }
            // Newest release (by version) that actually ships a macOS .dmg. Each
            // OS versions independently and a single tag may carry only the other
            // platform's assets, so verify the dmg exists before offering it —
            // a HEAD on the download host, still not the rate-limited API.
            let newer = parseAtom(xml)
                .filter { isNewer($0.version, than: currentVersion) }
                .sorted { isNewer($0.version, than: $1.version) }
            for entry in newer {
                let dmg = releaseDownloadURL(tag: entry.tag)
                if headOK(dmg) {
                    completion(.success(Release(version: entry.version, dmgURL: dmg,
                                                notes: notesFromAtom(entry.content))))
                    return
                }
            }
            // Nothing newer with a macOS build → report current (→ "up to date").
            completion(.success(Release(version: currentVersion, dmgURL: fallbackDMG, notes: "")))
        }.resume()
    }

    /// Parse the releases Atom feed into (version, tag, rawContentHTML) entries,
    /// in feed order. String-scanned rather than XML-parsed so the identical
    /// approach ports to the Windows updater without FoundationXML.
    static func parseAtom(_ xml: String) -> [(version: String, tag: String, content: String)] {
        var out: [(version: String, tag: String, content: String)] = []
        for e in xml.components(separatedBy: "<entry>").dropFirst() {
            guard let tag = between(e, "/releases/tag/", "\"") else { continue }
            var content = between(e, "<content", "</content>") ?? ""
            if let gt = content.firstIndex(of: ">") {   // drop the opening tag's attributes
                content = String(content[content.index(after: gt)...])
            }
            let version = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            out.append((version, tag, content))
        }
        return out
    }

    /// The substring strictly between `a` and the next `b` following it.
    static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r = s.range(of: a) else { return nil }
        let rest = s[r.upperBound...]
        guard let e = rest.range(of: b) else { return nil }
        return String(rest[..<e.lowerBound])
    }

    /// Synchronous HEAD: does the release ship this asset (2xx/3xx)? Runs on the
    /// atom fetch's background thread, so the brief block is harmless.
    private static func headOK(_ url: URL) -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let h = resp as? HTTPURLResponse { ok = (200..<400).contains(h.statusCode) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return ok
    }

    // MARK: GitHub API (fallback — unauthenticated, 60 requests/hour per IP)

    private static func fetchViaAPI(completion: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")   // GitHub API rejects UA-less requests
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let finish: (Result<Release, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            if let error { finish(.failure(error)); return }
            guard let http = resp as? HTTPURLResponse else { finish(.failure(err(L("update.error.network")))); return }
            if let rateErr = rateLimitError(http) { finish(.failure(rateErr)); return }
            guard (200..<300).contains(http.statusCode), let data else {
                finish(.failure(err(L("update.error.server") + " (\(http.statusCode))"))); return
            }
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                finish(.failure(err(L("update.error.parse")))); return
            }
            // Newest published release that ships a macOS .dmg — each OS
            // versions independently, so Windows-only releases are skipped.
            for json in list {
                if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { continue }
                guard let tag = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]] else { continue }
                let match = assets.first { ($0["name"] as? String) == stableDMGName }
                        ?? assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                guard let u = match?["browser_download_url"] as? String, let dmg = URL(string: u) else { continue }
                let version = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                finish(.success(Release(version: version, dmgURL: dmg,
                                        notes: changelogSection((json["body"] as? String) ?? ""))))
                return
            }
            // No release with a .dmg in the window — report as current so the
            // alert says "up to date" instead of offering a 404 download.
            finish(.success(Release(version: currentVersion, dmgURL: fallbackDMG, notes: "")))
        }.resume()
    }

    /// GitHub returns 403 (or 429) with `x-ratelimit-remaining: 0` when the
    /// unauthenticated 60/hr budget is spent. Turn that into a clear, actionable
    /// message (with a reset countdown) instead of a bare "server error".
    private static func rateLimitError(_ http: HTTPURLResponse) -> NSError? {
        guard http.statusCode == 403 || http.statusCode == 429,
              http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" else { return nil }
        if let resetStr = http.value(forHTTPHeaderField: "x-ratelimit-reset"), let reset = Double(resetStr) {
            let mins = max(1, Int(ceil((reset - Date().timeIntervalSince1970) / 60)))
            return err(L("update.error.ratelimit.wait").replacingOccurrences(of: "%d", with: "\(mins)"))
        }
        return err(L("update.error.ratelimit"))
    }

    /// The update dialog shows what changed, not the whole release page:
    /// release.sh puts the CHANGELOG.md section under a "## 변경 사항" heading,
    /// so extract it (up to the next "## " heading — the install instructions
    /// don't apply to an in-app update). Older releases without the heading
    /// fall back to the full body.
    static func changelogSection(_ body: String) -> String {
        guard let s = body.range(of: "## 변경 사항") else {
            // Pre-changelog release: show the body up to the install section.
            let head = body.components(separatedBy: "\n## 설치").first ?? body
            return head.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var notes = String(body[s.upperBound...])
        if let e = notes.range(of: "\n## ") { notes = String(notes[..<e.lowerBound]) }
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Atom feed carries the release body as rendered HTML, not markdown, so
    /// extract the "변경 사항" section and flatten it to plain text for the dialog.
    static func notesFromAtom(_ rawContent: String) -> String {
        let html = decodeEntities(rawContent)
        var section = html
        if let s = html.range(of: "변경 사항") {
            section = String(html[s.upperBound...])
            if let e = section.range(of: "<h2") { section = String(section[..<e.lowerBound]) }
        } else if let e = html.range(of: "<h2") {
            section = String(html[..<e.lowerBound])   // no heading → body up to the first section
        }
        return htmlToText(section)
    }

    private static func decodeEntities(_ s: String) -> String {
        var t = s
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                       ("&#39;", "'"), ("&#38;", "&"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: c)
        }
        return t
    }

    private static func htmlToText(_ html: String) -> String {
        var t = html
        for (tag, repl) in [("<li>", "- "), ("</li>", "\n"), ("<br>", "\n"), ("<br/>", "\n"),
                            ("<br />", "\n"), ("</p>", "\n"), ("</h2>", "\n"),
                            ("</ul>", "\n"), ("</ol>", "\n")] {
            t = t.replacingOccurrences(of: tag, with: repl, options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let lines = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Install + relaunch

    /// Replace the running `.app` with the one inside `dmgPath`, then relaunch.
    ///
    /// The app can't overwrite its own live bundle, so a detached shell script
    /// does it: launched as our child, it survives our termination (reparented
    /// to launchd), waits for our process to actually exit, swaps the bundle,
    /// and relaunches. So the user sees a brief quit → reopen, not an in-place
    /// hot-swap.
    ///
    /// The swap is staged (copy new bundle aside, then atomic rename) so a
    /// failed copy can never leave the user with no app. `preflight()` should
    /// have already rejected an unwritable install location before we quit.
    static func installAndRelaunch(dmgPath: URL) throws {
        try preflight()
        let target = Bundle.main.bundlePath           // e.g. /Applications/PokemonMouseFollower.app
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -e
        DMG=\(shellQuote(dmgPath.path))
        TARGET=\(shellQuote(target))
        SRCAPP=\(shellQuote(dmgAppName))
        STAGE="${TARGET}.new"
        BACKUP="${TARGET}.old"
        # Wait for the running app to quit before touching its bundle.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        MP="$(mktemp -d)"
        hdiutil attach -nobrowse -noverify -readonly -mountpoint "$MP" "$DMG" >/dev/null
        # Copy the new bundle aside FIRST — if this fails, TARGET is untouched.
        rm -rf "$STAGE"
        ditto "$MP/$SRCAPP" "$STAGE"
        hdiutil detach "$MP" >/dev/null 2>&1 || true
        xattr -dr com.apple.quarantine "$STAGE" >/dev/null 2>&1 || true
        # Same-directory renames are atomic; keep the old bundle until the new
        # one is in place so a crash mid-swap is recoverable.
        rm -rf "$BACKUP"
        mv "$TARGET" "$BACKUP" 2>/dev/null || true
        mv "$STAGE" "$TARGET"
        rm -rf "$BACKUP"
        rm -f "$DMG"
        open "$TARGET"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("pmf-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try p.run()
    }

    /// True/throws before we commit to quitting: the bundle must sit in a
    /// directory we can actually write to (a drag-installed /Applications copy
    /// is user-owned; a root-owned location is not).
    static func preflight() throws {
        let parent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) {
            throw err("설치 위치에 쓸 권한이 없습니다. 새 버전을 직접 내려받아 설치해 주세요.")
        }
    }

    /// Single-quote a path for safe embedding in the bash script.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Download (delegate-based, for progress)

/// One-shot download to a temp file with progress callbacks (all on main).
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private let onDone: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private let dest = FileManager.default.temporaryDirectory.appendingPathComponent("PMF-update.dmg")

    init(onProgress: @escaping (Double) -> Void, onDone: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onDone = onDone
        super.init()
    }

    func start(_ url: URL) {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: req).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let p = Double(written) / Double(expected)
        DispatchQueue.main.async { self.onProgress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Must move synchronously here — the temp file is deleted once we return.
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.onDone(.success(self.dest)) }
        } catch {
            DispatchQueue.main.async { self.onDone(.failure(error)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { DispatchQueue.main.async { self.onDone(.failure(error)) } }
    }
}

// MARK: - Progress HUD

/// Minimal titled window with a label + determinate progress bar, shown while
/// the update downloads/installs (this is a menu-bar accessory app with no
/// main window, so the flow needs its own surface).
final class UpdateProgressWindow {
    private let window: NSWindow
    private let label: NSTextField
    private let bar: NSProgressIndicator

    init() {
        // The content lays out in 1x coordinates and renders at the UI scale.
        let k = AppSettings.shared.uiScale
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340 * k, height: 92 * k),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Pokémon Mouse Follower"
        window.isReleasedWhenClosed = false
        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 50, width: 300, height: 20)
        bar = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 300, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let doc = NSView()
        doc.addSubview(label)
        doc.addSubview(bar)
        let host = UIZoomHost(document: doc)
        host.layoutZoomed(size1x: CGSize(width: 340, height: 92), k)
        window.contentView = host
    }

    func show(_ text: String) {
        label.stringValue = text
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func setText(_ t: String) { label.stringValue = t }

    func setProgress(_ p: Double) {
        if p <= 0 {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        } else {
            bar.isIndeterminate = false
            bar.doubleValue = p
        }
    }

    func close() { window.orderOut(nil) }

    /// Selftest: window size + content bounds ("WxH bounds WxH").
    var debugFrameString: String {
        let f = window.frame, b = window.contentView?.bounds ?? .zero
        return String(format: "%.0fx%.0f bounds %.0fx%.0f", f.width, f.height, b.width, b.height)
    }
}
