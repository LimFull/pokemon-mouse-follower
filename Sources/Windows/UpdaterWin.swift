// Self-update, Windows edition (design/windows-port.md W14): check the latest
// GitHub release, download PokemonMouseFollower-Setup.exe, run it silently
// (Inno Setup closes and relaunches the app), and quit. Mirrors the macOS
// Updater's version handling; releases without a Windows installer asset are
// treated as not-an-update so macOS-only releases never prompt here.

import WinSDK
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum UpdaterWin {
    static let owner = "LimFull"
    static let repo = "pokemon-mouse-follower"
    static let setupAssetSuffix = "-Setup.exe"

    private static var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
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

    private static func fetchLatest() -> Result<Release, Err> {
        var req = URLRequest(url: apiURL, timeoutInterval: 15)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, status) = requestSync(req) else { return .failure(Err(message: "network error")) }
        guard (200..<300).contains(status) else { return .failure(Err(message: "server error (\(status))")) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            return .failure(Err(message: "could not parse release info"))
        }
        var setup: URL? = nil
        if let assets = json["assets"] as? [[String: Any]] {
            let match = assets.first { ($0["name"] as? String)?.hasSuffix(setupAssetSuffix) == true }
            if let u = match?["browser_download_url"] as? String { setup = URL(string: u) }
        }
        let version = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "v "))
        guard let setup else {
            // No Windows installer in the latest release -> nothing to offer.
            return isNewer(version, than: AppVersion.string)
                ? .failure(Err(message: String(format: L("update.latest.body"), AppVersion.string)))
                : .success(Release(version: AppVersion.string, setupURL: apiURL, notes: ""))
        }
        return .success(Release(version: version, setupURL: setup,
                                notes: (json["body"] as? String) ?? ""))
    }

    private static func download(_ url: URL) -> Result<String, Err> {
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.setValue("PokemonMouseFollower", forHTTPHeaderField: "User-Agent")
        guard let (data, status) = requestSync(req), (200..<300).contains(status) else {
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
        var value: (Data, Int)?
    }

    private static func requestSync(_ req: URLRequest) -> (Data, Int)? {
        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let http = resp as? HTTPURLResponse {
                box.value = (data, http.statusCode)
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
