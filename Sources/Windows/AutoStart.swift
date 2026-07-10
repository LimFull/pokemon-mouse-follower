// Launch-at-login via the HKCU Run key (design/windows-port.md W11) — the
// Windows counterpart of the macOS SMAppService LoginItem. Per-user, no
// elevation needed; the value holds the quoted path of the running exe.

import WinSDK
import Foundation

enum LoginItem {
    private static let keyPath = Array(#"Software\Microsoft\Windows\CurrentVersion\Run"#.utf16) + [0]
    private static let valueName = Array("PokemonMouseFollower".utf16) + [0]
    // winnt.h composite access-right macros don't import into Swift.
    private static let kKEY_READ: DWORD = 0x20019
    private static let kKEY_SET_VALUE: DWORD = 0x0002

    private static var exePath: String {
        var buf = [WCHAR](repeating: 0, count: 1024)
        let n = GetModuleFileNameW(nil, &buf, DWORD(buf.count))
        return String(decoding: buf[0..<Int(n)], as: UTF16.self)
    }

    static var isEnabled: Bool {
        var hKey: HKEY? = nil
        let opened = keyPath.withUnsafeBufferPointer {
            RegOpenKeyExW(HKEY_CURRENT_USER, $0.baseAddress, 0, kKEY_READ, &hKey)
        }
        guard opened == ERROR_SUCCESS, let hKey else { return false }
        defer { RegCloseKey(hKey) }
        var type: DWORD = 0
        var size: DWORD = 0
        let status = valueName.withUnsafeBufferPointer {
            RegQueryValueExW(hKey, $0.baseAddress, nil, &type, nil, &size)
        }
        return status == ERROR_SUCCESS
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        var hKey: HKEY? = nil
        let opened = keyPath.withUnsafeBufferPointer {
            RegCreateKeyExW(HKEY_CURRENT_USER, $0.baseAddress, 0, nil, 0,
                            kKEY_SET_VALUE, nil, &hKey, nil)
        }
        guard opened == ERROR_SUCCESS, let hKey else { return false }
        defer { RegCloseKey(hKey) }
        if on {
            let value = Array("\"\(exePath)\"".utf16) + [0]
            let status = valueName.withUnsafeBufferPointer { name in
                value.withUnsafeBufferPointer { val in
                    val.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: val.count * 2) { bytes in
                        RegSetValueExW(hKey, name.baseAddress, 0, DWORD(REG_SZ),
                                       bytes, DWORD(val.count * 2))
                    }
                }
            }
            return status == ERROR_SUCCESS
        } else {
            let status = valueName.withUnsafeBufferPointer {
                RegDeleteValueW(hKey, $0.baseAddress)
            }
            return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND
        }
    }
}
