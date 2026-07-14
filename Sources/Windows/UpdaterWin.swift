// Self-update, Windows edition (design/windows-port.md W14): find the newest
// GitHub release that ships PokemonMouseFollower-Setup.exe, download it, run
// it silently (Inno Setup closes and relaunches the app), and quit. Mirrors
// the macOS Updater's version handling; macOS-only releases are skipped, so
// each OS updates on its own version track.

import WinSDK
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum UpdaterWin {
    static let owner = "LimFull"
    static let repo = "pokemon-mouse-follower"
    static let setupAssetSuffix = "-Setup.exe"

    /// Recent releases, newest first. `/releases/latest` may be a macOS-only
    /// release with no installer, so the check scans for the newest release
    /// that actually ships one.
    private static var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!
    }
    /// Releases Atom feed — a normal github.com page, NOT the rate-limited API.
    private static var atomURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases.atom")!
    }
    /// Versionless stable installer every Windows release publishes (release.ps1).
    private static let stableSetupName = "PokemonMouseFollower-Setup.exe"
    /// Conventional download URL for a tag's installer; a HEAD on it also tells
    /// us whether that tag ships a Windows build (vs. a macOS-only release).
    private static func releaseDownloadURL(tag: String) -> URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(stableSetupName)")!
    }

    struct Release {
        let version: String   // normalized, e.g. "1.8.0" (leading "v" stripped)
        let setupURL: URL
        let notes: String
    }

    private struct Err: Error { let message: String }

    /// "v1.4.0" -> [1, 4, 0]; non-numeric junk in a component drops to 0.
    private static func components(_ v: String) -> [Int] {
        v.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
         .split(separator: ".")
         .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = components(latest), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The update prompt shows what changed, not the whole release page:
    /// release.ps1 puts the CHANGELOG.md section under a "## 변경 사항"
    /// heading, so extract it (up to the next "## " heading — the install
    /// instructions don't apply to an in-app update). Older releases without
    /// the heading fall back to the full body. Mirrors Updater.changelogSection.
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

    private static var checking = false

    /// Tray-menu entry point. Network + prompts run off the tick thread;
    /// the final quit is posted back through the tray's window.
    static func checkForUpdate(quit: @escaping () -> Void) {
        guard !checking else { return }
        checking = true
        Thread.detachNewThread {
            defer { checking = false }
            switch fetchLatest() {
            case .failure(let e):
                alert(L("update.error"), e.message, warning: true)
            case .success(let rel):
                guard isNewer(rel.version, than: AppVersion.string) else {
                    alert(L("update.latest.title"),
                          String(format: L("update.latest.body"), AppVersion.string))
                    return
                }
                var body = String(format: L("update.available.body"), AppVersion.string, rel.version)
                if !rel.notes.isEmpty { body += "\n\n" + String(rel.notes.prefix(500)) }
                guard ask(String(format: L("update.available.title"), rel.version), body) else { return }
                switch download(rel.setupURL) {
                case .failure(let e):
                    alert(L("update.error"), e.message, warning: true)
                case .success(let setupPath):
                    // /CLOSEAPPLICATIONS lets the installer stop us if the quit
                    // below loses the race; the installer relaunches the app.
                    let args = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS"
                    let opened = "open".withCString(encodedAs: UTF16.self) { verb in
                        setupPath.withCString(encodedAs: UTF16.self) { file in
                            args.withCString(encodedAs: UTF16.self) { params in
                                ShellExecuteW(nil, verb, file, params, nil, SW_SHOWNORMAL)
                            }
                        }
                    }
                    if Int(bitPattern: opened) > 32 {
                        quit()
                    } else {
                        alert(L("update.error"), "installer launch failed", warning: true)
                    }
                }
            }
        }
    }

    // MARK: - blocking helpers (runs on the updater thread)

    /// Version check via the Atom feed first (see the macOS Updater for the
    /// rationale — the API's unauthenticated 60/hr-per-IP limit turns repeated
    /// checks into HTTP 403s). The API is the fallback when the feed is down.
    private static func fetchLatest() -> Result<Release, Err> {
        if let viaAtom = fetchViaAtom() { return viaAtom }
        return fetchViaAPI()
    }

    /// nil when the feed itself is unreachable (→ API fallback); otherwise
    /// .success with the update to offer or the current version ("up to date").
    private static func fetchViaAtom() -> Result<Release, Err>? {
        var req = URLRequest(url: atomURL, timeoutInterval: 15)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        guard let (data, http) = requestSync(req), (200..<300).contains(http.statusCode),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        // Newest release (by version) that actually ships a Windows installer;
        // verify with a HEAD on the download host (not the API) so a single tag
        // carrying only the macOS build is skipped.
        let newer = parseAtom(xml)
            .filter { isNewer($0.version, than: AppVersion.string) }
            .sorted { isNewer($0.version, than: $1.version) }
        for entry in newer {
            let setup = releaseDownloadURL(tag: entry.tag)
            if headOK(setup) {
                return .success(Release(version: entry.version, setupURL: setup,
                                        notes: notesFromAtom(entry.content)))
            }
        }
        return .success(Release(version: AppVersion.string, setupURL: apiURL, notes: ""))
    }

    private static func fetchViaAPI() -> Result<Release, Err> {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, http) = requestSync(req) else { return .failure(Err(message: L("update.error.network"))) }
        if let msg = rateLimitMessage(http) { return .failure(Err(message: msg)) }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(Err(message: L("update.error.server") + " (\(http.statusCode))"))
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(Err(message: L("update.error.parse")))
        }
        // Newest published release that ships a Windows installer — each OS
        // versions independently, so macOS-only releases are skipped.
        for json in list {
            if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { continue }
            guard let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else { continue }
            let match = assets.first { ($0["name"] as? String)?.hasSuffix(setupAssetSuffix) == true }
            guard let u = match?["browser_download_url"] as? String, let setup = URL(string: u) else { continue }
            let version = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            return .success(Release(version: version, setupURL: setup,
                                    notes: changelogSection((json["body"] as? String) ?? "")))
        }
        // No release with an installer in the window -> nothing to offer.
        return .success(Release(version: AppVersion.string, setupURL: apiURL, notes: ""))
    }

    /// 403/429 + `x-ratelimit-remaining: 0` → a clear, localized message.
    private static func rateLimitMessage(_ http: HTTPURLResponse) -> String? {
        guard http.statusCode == 403 || http.statusCode == 429,
              http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" else { return nil }
        if let resetStr = http.value(forHTTPHeaderField: "x-ratelimit-reset"), let reset = Double(resetStr) {
            let mins = max(1, Int(ceil((reset - Date().timeIntervalSince1970) / 60)))
            return L("update.error.ratelimit.wait").replacingOccurrences(of: "%d", with: "\(mins)")
        }
        return L("update.error.ratelimit")
    }

    // MARK: Atom parsing (mirrors macOS Updater; string-scanned, no FoundationXML)

    private static func parseAtom(_ xml: String) -> [(version: String, tag: String, content: String)] {
        var out: [(version: String, tag: String, content: String)] = []
        for e in xml.components(separatedBy: "<entry>").dropFirst() {
            guard let tag = between(e, "/releases/tag/", "\"") else { continue }
            var content = between(e, "<content", "</content>") ?? ""
            if let gt = content.firstIndex(of: ">") { content = String(content[content.index(after: gt)...]) }
            let version = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            out.append((version, tag, content))
        }
        return out
    }
    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r = s.range(of: a) else { return nil }
        let rest = s[r.upperBound...]
        guard let e = rest.range(of: b) else { return nil }
        return String(rest[..<e.lowerBound])
    }
    private static func notesFromAtom(_ rawContent: String) -> String {
        let html = decodeEntities(rawContent)
        var section = html
        if let s = html.range(of: "변경 사항") {
            section = String(html[s.upperBound...])
            if let e = section.range(of: "<h2") { section = String(section[..<e.lowerBound]) }
        } else if let e = html.range(of: "<h2") { section = String(html[..<e.lowerBound]) }
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

    private static func headOK(_ url: URL) -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        if let (_, http) = requestSync(req) { return (200..<400).contains(http.statusCode) }
        return false
    }

    private static func download(_ url: URL) -> Result<String, Err> {
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        guard let (data, http) = requestSync(req), (200..<300).contains(http.statusCode) else {
            return .failure(Err(message: "download failed"))
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PMF-update-Setup.exe")
        do {
            try data.write(to: dest, options: .atomic)
            return .success(dest.path)
        } catch {
            return .failure(Err(message: "could not save installer: \(error.localizedDescription)"))
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        var value: (Data, HTTPURLResponse)?
    }

    private static func requestSync(_ req: URLRequest) -> (Data, HTTPURLResponse)? {
        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let http = resp as? HTTPURLResponse {
                box.value = (data, http)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 320)
        return box.value
    }

    // MARK: - message boxes (fine off the main thread)

    private static func alert(_ title: String, _ text: String, warning: Bool = false) {
        _ = title.withCString(encodedAs: UTF16.self) { t in
            text.withCString(encodedAs: UTF16.self) { b in
                MessageBoxW(nil, b, t, UINT(MB_OK) | UINT(warning ? MB_ICONWARNING : MB_ICONINFORMATION))
            }
        }
    }

    private static func ask(_ title: String, _ text: String) -> Bool {
        let answer = title.withCString(encodedAs: UTF16.self) { t in
            text.withCString(encodedAs: UTF16.self) { b in
                MessageBoxW(nil, b, t, UINT(MB_YESNO) | UINT(MB_ICONINFORMATION))
            }
        }
        return answer == IDYES
    }
}
