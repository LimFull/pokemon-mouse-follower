// Phase 0 spike ②: transparent click-through layered window that follows the
// cursor at 60fps, showing an animated Squirtle walk cycle (2x nearest scale).
// Probes: GDI+ flat API (PNG decode), CreateDIBSection, UpdateLayeredWindow
// (per-pixel alpha + move in one call), GetCursorPos polling, WS_EX_LAYERED|
// TRANSPARENT|TOOLWINDOW|NOACTIVATE|TOPMOST, multi-monitor metrics,
// CreateWaitableTimerExW availability. Auto-exits after ~20 seconds.

import WinSDK
import Foundation

// MARK: - constants the Swift WinSDK module may not surface as usable types
let kWS_EX_LAYERED: DWORD = 0x0008_0000
let kWS_EX_TRANSPARENT: DWORD = 0x0000_0020
let kWS_EX_TOOLWINDOW: DWORD = 0x0000_0080
let kWS_EX_NOACTIVATE: DWORD = 0x0800_0000
let kWS_EX_TOPMOST: DWORD = 0x0000_0008
let kWS_POPUP: DWORD = 0x8000_0000
let kULW_ALPHA: DWORD = 2
let kSW_SHOWNA: Int32 = 8

func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

// MARK: - GDI+ flat API via dynamic binding (checklist: not exposed by WinSDK
// module directly — gdiplus.h is C++; the flat exports are plain C functions)
struct GpStartupInput {
    var version: UInt32 = 1
    var debugCallback: UnsafeMutableRawPointer? = nil
    var suppressBackgroundThread: Int32 = 0
    var suppressExternalCodecs: Int32 = 0
}
struct GpBitmapData {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var stride: Int32 = 0
    var pixelFormat: Int32 = 0
    var scan0: UnsafeMutableRawPointer? = nil
    var reserved: UInt = 0
}
struct GpRect { var x: Int32; var y: Int32; var w: Int32; var h: Int32 }

let kPixelFormat32bppPARGB: Int32 = 0x000E200B   // premultiplied BGRA, DIB-compatible
let kImageLockModeRead: UInt32 = 1

// Swift-defined structs are not allowed in @convention(c) signatures, so
// struct pointers cross as raw pointers.
typealias FnGdiplusStartup = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Int32
typealias FnCreateBitmapFromFile = @convention(c) (
    UnsafePointer<UInt16>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
typealias FnGetImageDim = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> Int32
typealias FnBitmapLockBits = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeRawPointer?, UInt32, Int32,
    UnsafeMutableRawPointer?) -> Int32
typealias FnBitmapUnlockBits = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

guard let gdiplus = LoadLibraryW(wide("gdiplus.dll")) else { fatalError("no gdiplus.dll") }
func gpProc<T>(_ name: String, _ type: T.Type) -> T {
    guard let p = GetProcAddress(gdiplus, name) else { fatalError("missing \(name)") }
    return unsafeBitCast(p, to: T.self)
}
let GdiplusStartup = gpProc("GdiplusStartup", FnGdiplusStartup.self)
let GdipCreateBitmapFromFile = gpProc("GdipCreateBitmapFromFile", FnCreateBitmapFromFile.self)
let GdipGetImageWidth = gpProc("GdipGetImageWidth", FnGetImageDim.self)
let GdipGetImageHeight = gpProc("GdipGetImageHeight", FnGetImageDim.self)
let GdipBitmapLockBits = gpProc("GdipBitmapLockBits", FnBitmapLockBits.self)
let GdipBitmapUnlockBits = gpProc("GdipBitmapUnlockBits", FnBitmapUnlockBits.self)

// MARK: - decode the walk sheet and slice 4 premultiplied-BGRA 32x32 frames
let sheetPath = "C:\\가득\\pokemon-mouse-follower\\animations\\007\\Walk-Anim.png"
let frameSrc = 32                      // FrameWidth/Height (AnimData.xml row 0)
let scale = 2
let frameDst = frameSrc * scale        // 64x64 window

var gpToken: UInt = 0
var gpInput = GpStartupInput()
let gpStartStatus = withUnsafeMutablePointer(to: &gpToken) { tok in
    withUnsafePointer(to: &gpInput) { inp in
        GdiplusStartup(UnsafeMutableRawPointer(tok), UnsafeRawPointer(inp), nil)
    }
}
precondition(gpStartStatus == 0, "GdiplusStartup failed: \(gpStartStatus)")

var gpBitmap: UnsafeMutableRawPointer? = nil
let pathW = wide(sheetPath)
let createStatus = pathW.withUnsafeBufferPointer { GdipCreateBitmapFromFile($0.baseAddress, &gpBitmap) }
precondition(createStatus == 0 && gpBitmap != nil, "GdipCreateBitmapFromFile failed: \(createStatus)")

var sheetW: UInt32 = 0, sheetH: UInt32 = 0
_ = GdipGetImageWidth(gpBitmap, &sheetW)
_ = GdipGetImageHeight(gpBitmap, &sheetH)
print("sheet decoded: \(sheetW)x\(sheetH) from \(sheetPath)")

// frames[i] = 32x32 premultiplied BGRA rows (row 0 of the sheet = walk down)
var frames: [[UInt8]] = []
for i in 0..<4 {
    var rect = GpRect(x: Int32(i * frameSrc), y: 0, w: Int32(frameSrc), h: Int32(frameSrc))
    var data = GpBitmapData()
    let st = withUnsafePointer(to: &rect) { r in
        withUnsafeMutablePointer(to: &data) { d in
            GdipBitmapLockBits(gpBitmap, UnsafeRawPointer(r), kImageLockModeRead,
                               kPixelFormat32bppPARGB, UnsafeMutableRawPointer(d))
        }
    }
    precondition(st == 0, "LockBits failed: \(st)")
    var buf = [UInt8](repeating: 0, count: frameSrc * frameSrc * 4)
    let src = data.scan0!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<frameSrc {
        let srcRow = src + row * Int(data.stride)
        _ = buf.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress! + row * frameSrc * 4, srcRow, frameSrc * 4)
        }
    }
    frames.append(buf)
    _ = withUnsafeMutablePointer(to: &data) { d in
        GdipBitmapUnlockBits(gpBitmap, UnsafeMutableRawPointer(d))
    }
}
print("frames sliced: \(frames.count) x \(frameSrc)x\(frameSrc) premultiplied BGRA")

// MARK: - multi-monitor metrics (checklist)
let monitors = GetSystemMetrics(80)  // SM_CMONITORS
let vx = GetSystemMetrics(76), vy = GetSystemMetrics(77)   // SM_[XY]VIRTUALSCREEN
let vw = GetSystemMetrics(78), vh = GetSystemMetrics(79)   // SM_C[XY]VIRTUALSCREEN
print("monitors=\(monitors) virtualScreen=(\(vx),\(vy)) \(vw)x\(vh)")

// probe: high-resolution waitable timer symbol available (W5)
let timerProbe = CreateWaitableTimerExW(nil, nil, 0x00000002 /*HIGH_RESOLUTION*/, 0x1F0003)
print("CreateWaitableTimerExW(HIGH_RESOLUTION): \(timerProbe != nil ? "ok" : "unavailable")")
if let t = timerProbe { CloseHandle(t) }

// MARK: - layered window
let hInstance = GetModuleHandleW(nil)
let className = wide("PMFSpikeOverlay")

var wc = WNDCLASSW()
wc.style = 0
wc.lpfnWndProc = { hwnd, msg, wParam, lParam -> LRESULT in
    switch msg {
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}
wc.hInstance = hInstance
className.withUnsafeBufferPointer { wc.lpszClassName = $0.baseAddress }
precondition(RegisterClassW(&wc) != 0, "RegisterClassW failed: \(GetLastError())")

var cursor0 = POINT()
GetCursorPos(&cursor0)
let exStyle = kWS_EX_LAYERED | kWS_EX_TRANSPARENT | kWS_EX_TOOLWINDOW | kWS_EX_NOACTIVATE | kWS_EX_TOPMOST
let hwnd: HWND? = className.withUnsafeBufferPointer { cls in
    wide("PMF Spike").withUnsafeBufferPointer { title in
        CreateWindowExW(exStyle, cls.baseAddress, title.baseAddress, kWS_POPUP,
                        cursor0.x, cursor0.y, Int32(frameDst), Int32(frameDst),
                        nil, nil, hInstance, nil)
    }
}
precondition(hwnd != nil, "CreateWindowExW failed: \(GetLastError())")
ShowWindow(hwnd, kSW_SHOWNA)

// 64x64 top-down BGRA DIB the frames get nearest-scaled into
var bmi = BITMAPINFO()
bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
bmi.bmiHeader.biWidth = Int32(frameDst)
bmi.bmiHeader.biHeight = -Int32(frameDst)
bmi.bmiHeader.biPlanes = 1
bmi.bmiHeader.biBitCount = 32
bmi.bmiHeader.biCompression = DWORD(BI_RGB)

let hdcScreen = GetDC(nil)
let hdcMem = CreateCompatibleDC(hdcScreen)
var dibBits: UnsafeMutableRawPointer? = nil
let hDib = CreateDIBSection(hdcScreen, &bmi, UINT(DIB_RGB_COLORS), &dibBits, nil, 0)
precondition(hDib != nil && dibBits != nil, "CreateDIBSection failed")
SelectObject(hdcMem, hDib)

func blitFrame(_ idx: Int) {
    let dst = dibBits!.assumingMemoryBound(to: UInt32.self)
    frames[idx].withUnsafeBytes { raw in
        let src = raw.bindMemory(to: UInt32.self)
        for y in 0..<frameDst {
            let sy = y / scale
            for x in 0..<frameDst {
                dst[y * frameDst + x] = src[sy * frameSrc + x / scale]
            }
        }
    }
}

func present(x: Int32, y: Int32, frame: Int) -> Bool {
    blitFrame(frame)
    var ptSrc = POINT(x: 0, y: 0)
    var sz = SIZE(cx: Int32(frameDst), cy: Int32(frameDst))
    var ptDst = POINT(x: x, y: y)
    var blend = BLENDFUNCTION(BlendOp: 0 /*AC_SRC_OVER*/, BlendFlags: 0,
                              SourceConstantAlpha: 255, AlphaFormat: 1 /*AC_SRC_ALPHA*/)
    return UpdateLayeredWindow(hwnd, nil, &ptDst, &sz, hdcMem, &ptSrc, 0, &blend, kULW_ALPHA)
}

// MARK: - 60fps follow loop (SetTimer is enough for the PoC; W5 uses the
// high-res waitable timer verified above)
var posX = Double(cursor0.x), posY = Double(cursor0.y)
var tick = 0
var ulwFailures = 0

SetTimer(hwnd, 1, 16, nil)
let started = GetTickCount64()

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    if msg.message == UINT(WM_TIMER) {
        tick += 1
        var c = POINT()
        GetCursorPos(&c)
        // trail 40px below-right of the hotspot, eased like the real follower
        posX += (Double(c.x) + 24 - posX) * 0.08
        posY += (Double(c.y) + 24 - posY) * 0.08
        let frame = (tick / 8) % 4
        if !present(x: Int32(posX), y: Int32(posY), frame: frame) { ulwFailures += 1 }
        if tick % 120 == 0 {
            print("tick \(tick): cursor=(\(c.x),\(c.y)) sprite=(\(Int(posX)),\(Int(posY))) ulwFailures=\(ulwFailures)")
        }
        if GetTickCount64() - started > 20_000 { DestroyWindow(hwnd) }
    } else {
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }
}

print(ulwFailures == 0 ? "=== OVERLAY POC OK (\(tick) ticks, 0 ULW failures) ==="
                       : "=== OVERLAY POC: \(ulwFailures) ULW failures in \(tick) ticks ===")
