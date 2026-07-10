// Virtual-desktop fallback (design/windows-port.md §6-2): Windows has no
// canJoinAllSpaces equivalent, so the overlay windows stay behind when the
// user switches desktops. IVirtualDesktopManager (documented COM API) tells
// us when our windows left the current desktop; the current desktop's GUID is
// learned from the foreground window and every overlay is moved over.

import WinSDK
import Foundation

// COM vtable call plumbing (same dynamic-binding approach as GDI+ in
// PlatformWin.swift; GUID is a C-imported struct so it may cross
// @convention(c) boundaries).
private typealias FnHResultHwndBool = @convention(c) (
    UnsafeMutableRawPointer?, HWND?, UnsafeMutablePointer<Int32>?) -> Int32
private typealias FnHResultHwndGuid = @convention(c) (
    UnsafeMutableRawPointer?, HWND?, UnsafeMutablePointer<GUID>?) -> Int32
private typealias FnHResultHwndRefGuid = @convention(c) (
    UnsafeMutableRawPointer?, HWND?, UnsafePointer<GUID>?) -> Int32

enum VirtualDesktop {
    // CLSID_VirtualDesktopManager {aa509086-5ca9-4c25-8f95-589d3c07b48a}
    private static var clsid = GUID(
        Data1: 0xAA50_9086, Data2: 0x5CA9, Data3: 0x4C25,
        Data4: (0x8F, 0x95, 0x58, 0x9D, 0x3C, 0x07, 0xB4, 0x8A))
    // IID_IVirtualDesktopManager {a5cd92ff-29be-454c-8d04-d82879fb3f1b}
    private static var iid = GUID(
        Data1: 0xA5CD_92FF, Data2: 0x29BE, Data3: 0x454C,
        Data4: (0x8D, 0x04, 0xD8, 0x28, 0x79, 0xFB, 0x3F, 0x1B))

    /// The IVirtualDesktopManager instance (nil when unavailable — older
    /// Windows or a COM failure; the feature silently disables itself).
    private static let manager: UnsafeMutableRawPointer? = {
        // Main thread, once, before the first poll.
        _ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        var obj: UnsafeMutableRawPointer? = nil
        let hr = withUnsafePointer(to: &clsid) { c in
            withUnsafePointer(to: &iid) { i in
                CoCreateInstance(c, nil, DWORD(0x1) /*CLSCTX_INPROC_SERVER*/, i, &obj)
            }
        }
        return hr == 0 ? obj : nil
    }()

    private static func method<T>(_ index: Int, _ type: T.Type) -> T? {
        guard let manager else { return nil }
        let vtbl = manager.load(as: UnsafeMutableRawPointer.self)
        return unsafeBitCast(vtbl.load(fromByteOffset: index * MemoryLayout<UnsafeRawPointer>.size,
                                       as: UnsafeRawPointer.self), to: T.self)
    }

    // IUnknown(0..2), IsWindowOnCurrentVirtualDesktop(3), GetWindowDesktopId(4),
    // MoveWindowToDesktop(5) — the interface's documented method order.
    private static func isOnCurrentDesktop(_ hwnd: HWND) -> Bool? {
        guard let fn = method(3, FnHResultHwndBool.self) else { return nil }
        var on: Int32 = 1
        return fn(manager, hwnd, &on) == 0 ? (on != 0) : nil
    }

    private static func desktopId(of hwnd: HWND) -> GUID? {
        guard let fn = method(4, FnHResultHwndGuid.self) else { return nil }
        var id = GUID()
        guard fn(manager, hwnd, &id) == 0 else { return nil }
        let zero = id.Data1 == 0 && id.Data2 == 0 && id.Data3 == 0
            && id.Data4.0 == 0 && id.Data4.1 == 0 && id.Data4.2 == 0 && id.Data4.3 == 0
            && id.Data4.4 == 0 && id.Data4.5 == 0 && id.Data4.6 == 0 && id.Data4.7 == 0
        return zero ? nil : id
    }

    private static func move(_ hwnd: HWND, to id: GUID) {
        guard let fn = method(5, FnHResultHwndRefGuid.self) else { return }
        var target = id
        _ = withUnsafePointer(to: &target) { fn(manager, hwnd, $0) }
    }

    /// Poll hook (a few times a second is plenty): when the overlays are no
    /// longer on the active desktop, learn the active desktop's GUID from the
    /// foreground window and bring every overlay over. Own windows are always
    /// movable, so no extra permissions apply.
    static func keepOverlaysOnCurrentDesktop() {
        guard manager != nil, let probe = allOverlayWindows.first else { return }
        guard isOnCurrentDesktop(probe) == false else { return }
        // Our overlays are WS_EX_NOACTIVATE, so the foreground window belongs
        // to whatever the user is actually using on the new desktop. Pinned
        // shell windows report a zero GUID and are skipped (retry next poll).
        guard let fg = GetForegroundWindow(), let id = desktopId(of: fg) else { return }
        for hwnd in allOverlayWindows { move(hwnd, to: id) }
    }
}
