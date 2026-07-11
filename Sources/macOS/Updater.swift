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

    static func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")   // GitHub API rejects UA-less requests
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let finish: (Result<Release, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            if let error { finish(.failure(error)); return }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                finish(.failure(err("서버 응답 오류"))); return
            }
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                finish(.failure(err("릴리스 정보를 해석할 수 없습니다"))); return
            }
            // Newest published release that ships a macOS .dmg — each OS
            // versions independently, so Windows-only releases are skipped.
            let dmgName = dmgAppName.replacingOccurrences(of: ".app", with: ".dmg")
            for json in list {
                if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { continue }
                guard let tag = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]] else { continue }
                let match = assets.first { ($0["name"] as? String) == dmgName }
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
