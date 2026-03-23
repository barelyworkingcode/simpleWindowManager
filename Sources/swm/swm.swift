import ArgumentParser
import AppKit
import CoreGraphics

@main
struct SWM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swm",
        abstract: "Simple window manager for multi-display setups.",
        subcommands: [CyclePrimary.self, CycleSecondary.self, SwapForemost.self, PushToSecondary.self, PullToPrimary.self, ToggleFillCenter.self]
    )
}

// MARK: - Subcommands

struct CyclePrimary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cycle-primary",
        abstract: "Cycle windows on the primary display: bring the bottom-most window to the top."
    )

    func run() throws {
        try ensureAccessibility()
        let screen = primaryScreen()
        try cycleWindows(on: screen)
    }
}

struct CycleSecondary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cycle-secondary",
        abstract: "Cycle windows on the secondary display: bring the bottom-most window to the top."
    )

    func run() throws {
        try ensureAccessibility()
        guard let screen = secondaryScreen() else {
            print("No secondary display found.")
            throw ExitCode.failure
        }
        try cycleWindows(on: screen)
    }
}

struct SwapForemost: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swap",
        abstract: "Swap the foremost windows between primary and secondary displays."
    )

    func run() throws {
        try ensureAccessibility()
        let primary = primaryScreen()
        guard let secondary = secondaryScreen() else {
            print("No secondary display found.")
            throw ExitCode.failure
        }
        try swapForemost(primary: primary, secondary: secondary)
    }
}

struct ToggleFillCenter: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Toggle the foremost window between filling the screen and a centered size."
    )

    func run() throws {
        try ensureAccessibility()
        try toggleFillCenter()
    }
}

struct PushToSecondary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push the foremost window on the primary display to the secondary display."
    )

    func run() throws {
        try ensureAccessibility()
        let primary = primaryScreen()
        guard let secondary = secondaryScreen() else {
            print("No secondary display found.")
            throw ExitCode.failure
        }
        try pushWindow(from: primary, to: secondary)
    }
}

struct PullToPrimary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Pull the foremost window on the secondary display to the primary display."
    )

    func run() throws {
        try ensureAccessibility()
        let primary = primaryScreen()
        guard let secondary = secondaryScreen() else {
            print("No secondary display found.")
            throw ExitCode.failure
        }
        try pullWindow(from: secondary, to: primary)
    }
}

// MARK: - Accessibility check

func ensureAccessibility() throws {
    // The value of kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"
    let trusted = AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    )
    if !trusted {
        print("Accessibility permission required. A system prompt should appear.")
        print("Grant permission in System Settings > Privacy & Security > Accessibility, then retry.")
        throw ExitCode.failure
    }
}

// MARK: - Screen helpers

func primaryScreen() -> NSScreen {
    // NSScreen.screens[0] is always the primary display
    return NSScreen.screens[0]
}

func secondaryScreen() -> NSScreen? {
    guard NSScreen.screens.count > 1 else { return nil }
    return NSScreen.screens[1]
}

func screenContaining(rect: CGRect) -> NSScreen? {
    // CGWindow coordinates: origin at top-left of primary display, Y increases downward.
    // NSScreen coordinates: origin at bottom-left of primary display, Y increases upward.
    // We compare using CGWindow-style coordinates.
    let windowCenter = CGPoint(x: rect.midX, y: rect.midY)
    for screen in NSScreen.screens {
        let frame = screen.frame
        let primaryHeight = NSScreen.screens[0].frame.height
        // Convert NSScreen frame to CGWindow coordinate space
        let cgOriginY = primaryHeight - frame.maxY
        let cgFrame = CGRect(x: frame.origin.x, y: cgOriginY, width: frame.width, height: frame.height)
        if cgFrame.contains(windowCenter) {
            return screen
        }
    }
    return nil
}

// MARK: - Window info from CGWindowList

struct WindowInfo {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let bounds: CGRect
    let ownerName: String
    let windowLayer: Int
}

func getVisibleWindows() -> [WindowInfo] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    var results: [WindowInfo] = []
    for entry in windowList {
        guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let wid = entry[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
              let layer = entry[kCGWindowLayer as String] as? Int,
              layer == 0 // normal window layer
        else { continue }

        let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""

        // Skip Finder desktop window and system UI elements
        if ownerName == "Window Server" || ownerName == "Dock" { continue }

        let bounds = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )

        // Skip small windows (menu bar extras, status items, toolbars, overlays)
        if bounds.width < 100 || bounds.height < 200 { continue }

        results.append(WindowInfo(
            ownerPID: pid,
            windowID: wid,
            bounds: bounds,
            ownerName: ownerName,
            windowLayer: layer
        ))
    }
    return results
}

func windowsOnScreen(_ screen: NSScreen, from windows: [WindowInfo]) -> [WindowInfo] {
    return windows.filter { screenContaining(rect: $0.bounds) == screen }
}

// MARK: - AXUIElement helpers

func axWindowForInfo(_ info: WindowInfo) -> AXUIElement? {
    let app = AXUIElementCreateApplication(info.ownerPID)
    var axWindows: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &axWindows)
    guard result == .success, let windowArray = axWindows as? [AXUIElement] else { return nil }

    var largestWindow: AXUIElement?
    var largestArea: CGFloat = 0

    for axWin in windowArray {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &posVal)
        AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeVal)

        var pos = CGPoint.zero
        var size = CGSize.zero
        if let posVal = posVal {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        }
        if let sizeVal = sizeVal {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        let axBounds = CGRect(origin: pos, size: size)
        // Exact match by position (allow tolerance for rounding)
        if abs(axBounds.origin.x - info.bounds.origin.x) < 10
            && abs(axBounds.origin.y - info.bounds.origin.y) < 10
            && abs(axBounds.width - info.bounds.width) < 10
            && abs(axBounds.height - info.bounds.height) < 10 {
            return axWin
        }

        // Track the largest AX window as fallback (for Electron/Chromium apps
        // whose CG windows don't map 1:1 to AX windows)
        let area = size.width * size.height
        if area > largestArea {
            largestArea = area
            largestWindow = axWin
        }
    }

    return largestWindow
}

func raiseWindow(_ axWindow: AXUIElement, pid: pid_t) {
    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
    let app = NSRunningApplication(processIdentifier: pid)
    app?.activate(options: .activateIgnoringOtherApps)
}

func setWindowPosition(_ axWindow: AXUIElement, position: CGPoint) {
    var pos = position
    if let value = AXValueCreate(.cgPoint, &pos) {
        AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value)
    }
}

func setWindowSize(_ axWindow: AXUIElement, size: CGSize) {
    var sz = size
    if let value = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value)
    }
}

func getWindowPosition(_ axWindow: AXUIElement) -> CGPoint? {
    var posVal: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posVal)
    guard let posVal = posVal else { return nil }
    var pos = CGPoint.zero
    AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
    return pos
}

func getWindowSize(_ axWindow: AXUIElement) -> CGSize? {
    var sizeVal: CFTypeRef?
    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeVal)
    guard let sizeVal = sizeVal else { return nil }
    var size = CGSize.zero
    AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
    return size
}

// MARK: - Screen frame in CG coordinates

/// Returns the visible frame of a screen in CGWindow coordinate space (origin top-left of primary, Y down).
func visibleFrameInCG(_ screen: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens[0].frame.height
    let visible = screen.visibleFrame
    let full = screen.frame
    // Convert from NSScreen coords (bottom-left origin) to CG coords (top-left origin)
    let cgY = primaryHeight - (full.origin.y + full.height) + (full.height - visible.maxY + full.origin.y)
    return CGRect(x: visible.origin.x, y: cgY, width: visible.width, height: visible.height)
}

/// Returns the full frame of a screen in CGWindow coordinate space.
func fullFrameInCG(_ screen: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens[0].frame.height
    let frame = screen.frame
    let cgY = primaryHeight - frame.maxY
    return CGRect(x: frame.origin.x, y: cgY, width: frame.width, height: frame.height)
}

// MARK: - Margin-based window placement

/// Moves a window from one screen to another, preserving margins as proportions
/// of the screen size. A window that's full-screen (0% margins) stays full-screen.
/// A window inset 10% from each edge stays 10% inset on the destination.
///
/// After requesting the size, re-reads the actual size the app accepted (some apps
/// have max/min size constraints) and centers within the intended area if it differs.
func moveWindow(_ axWindow: AXUIElement, from src: CGRect, to dst: CGRect, windowBounds: CGRect) {
    // Express margins as fractions of the source screen dimensions
    let fracLeft   = (windowBounds.origin.x - src.origin.x) / src.width
    let fracTop    = (windowBounds.origin.y - src.origin.y) / src.height
    let fracRight  = (src.maxX - windowBounds.maxX) / src.width
    let fracBottom = (src.maxY - windowBounds.maxY) / src.height

    // Apply those fractions to the destination screen
    let dstMarginLeft   = fracLeft * dst.width
    let dstMarginTop    = fracTop * dst.height
    let dstMarginRight  = fracRight * dst.width
    let dstMarginBottom = fracBottom * dst.height

    let requestedW = max(dst.width - dstMarginLeft - dstMarginRight, 200)
    let requestedH = max(dst.height - dstMarginTop - dstMarginBottom, 200)

    // Move the window to the destination screen FIRST — apps constrain size
    // based on the screen the window is currently on.
    setWindowPosition(axWindow, position: CGPoint(x: dst.origin.x, y: dst.origin.y))

    // Let the window server register the screen change before resizing
    usleep(50_000)

    // Now resize on the destination screen
    setWindowSize(axWindow, size: CGSize(width: min(requestedW, dst.width), height: min(requestedH, dst.height)))

    // Some apps need a second pass to accept the full size after moving screens
    usleep(50_000)
    setWindowSize(axWindow, size: CGSize(width: min(requestedW, dst.width), height: min(requestedH, dst.height)))

    // Re-read the actual size the app accepted
    let actualSize = getWindowSize(axWindow) ?? CGSize(width: requestedW, height: requestedH)
    let actualW = actualSize.width
    let actualH = actualSize.height

    // Center the window within the intended margin area
    let areaX = dst.origin.x + dstMarginLeft
    let areaY = dst.origin.y + dstMarginTop
    let areaW = max(dst.width - dstMarginLeft - dstMarginRight, actualW)
    let areaH = max(dst.height - dstMarginTop - dstMarginBottom, actualH)

    var newX = areaX + (areaW - actualW) / 2
    var newY = areaY + (areaH - actualH) / 2

    // Clamp so the window stays within the destination visible area
    if newX + actualW > dst.maxX { newX = dst.maxX - actualW }
    if newY + actualH > dst.maxY { newY = dst.maxY - actualH }
    newX = max(newX, dst.origin.x)
    newY = max(newY, dst.origin.y)

    setWindowPosition(axWindow, position: CGPoint(x: newX, y: newY))
}

// MARK: - Cycle windows

func cycleWindows(on screen: NSScreen) throws {
    let allWindows = getVisibleWindows()
    let onScreen = windowsOnScreen(screen, from: allWindows)

    guard onScreen.count > 1 else {
        if onScreen.isEmpty {
            print("No windows found on this display.")
        } else {
            print("Only one window on this display, nothing to cycle.")
        }
        return
    }

    // The CGWindowList returns windows in front-to-back order.
    // The last window in the list for this screen is the bottom-most.
    let bottomWindow = onScreen.last!

    guard let axWindow = axWindowForInfo(bottomWindow) else {
        print("Could not get accessibility reference for bottom window (\(bottomWindow.ownerName)).")
        throw ExitCode.failure
    }

    raiseWindow(axWindow, pid: bottomWindow.ownerPID)
    print("Raised '\(bottomWindow.ownerName)' to the top on \(screen == primaryScreen() ? "primary" : "secondary") display.")
}

// MARK: - Toggle fill / center

func toggleFillCenter() throws {
    // Get the frontmost application's focused window — works regardless of which monitor it's on
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        print("No frontmost application.")
        throw ExitCode.failure
    }
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var focusedRef: CFTypeRef?
    let axResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef)
    guard axResult == .success, let axWin = focusedRef else {
        print("Could not get focused window for '\(frontApp.localizedName ?? "unknown")'.")
        throw ExitCode.failure
    }
    let axWindow = axWin as! AXUIElement

    guard let pos = getWindowPosition(axWindow), let size = getWindowSize(axWindow) else {
        print("Could not read window geometry.")
        throw ExitCode.failure
    }
    let winBounds = CGRect(origin: pos, size: size)
    let appName = frontApp.localizedName ?? "unknown"

    guard let screen = screenContaining(rect: winBounds) else {
        print("Could not determine screen for '\(appName)'.")
        throw ExitCode.failure
    }

    let visible = visibleFrameInCG(screen)
    let full = fullFrameInCG(screen)

    // Check if window is currently filling the visible area (within tolerance)
    let tolerance: CGFloat = 10
    let isFilled = abs(winBounds.origin.x - visible.origin.x) <= tolerance
        && abs(winBounds.origin.y - visible.origin.y) <= tolerance
        && abs(winBounds.width - visible.width) <= tolerance
        && abs(winBounds.height - visible.height) <= tolerance

    if isFilled {
        // Switch to centered layout: 60% width, 75% height
        let centerW = full.width * 0.6
        let centerH = visible.height * 0.75
        let centerX = full.origin.x + (full.width - centerW) / 2
        let centerY = visible.origin.y + (visible.height - centerH) / 2
        setWindowSize(axWindow, size: CGSize(width: centerW, height: centerH))
        setWindowPosition(axWindow, position: CGPoint(x: centerX, y: centerY))
        print("Centered '\(appName)'.")
    } else {
        // Switch to fill layout
        setWindowPosition(axWindow, position: CGPoint(x: visible.origin.x, y: visible.origin.y))
        setWindowSize(axWindow, size: CGSize(width: visible.width, height: visible.height))
        print("Filled '\(appName)'.")
    }
}

// MARK: - Push / Pull

func pushWindow(from src: NSScreen, to dst: NSScreen) throws {
    let allWindows = getVisibleWindows()
    let onSrc = windowsOnScreen(src, from: allWindows)

    guard let win = onSrc.first else {
        print("No windows on source display to push.")
        throw ExitCode.failure
    }
    guard let axWin = axWindowForInfo(win) else {
        print("Could not get accessibility reference for '\(win.ownerName)'.")
        throw ExitCode.failure
    }

    let srcVisible = visibleFrameInCG(src)
    let dstVisible = visibleFrameInCG(dst)
    moveWindow(axWin, from: srcVisible, to: dstVisible, windowBounds: win.bounds)
    raiseWindow(axWin, pid: win.ownerPID)

    // Raise the next available window on the source display
    let remaining = onSrc.dropFirst().first { $0.windowID != win.windowID }
    if let next = remaining, let axNext = axWindowForInfo(next) {
        raiseWindow(axNext, pid: next.ownerPID)
    }

    print("Pushed '\(win.ownerName)' to \(dst == primaryScreen() ? "primary" : "secondary") display.")
}

func pullWindow(from src: NSScreen, to dst: NSScreen) throws {
    let allWindows = getVisibleWindows()
    let onSrc = windowsOnScreen(src, from: allWindows)

    guard let win = onSrc.first else {
        print("No windows on source display to pull.")
        throw ExitCode.failure
    }
    guard let axWin = axWindowForInfo(win) else {
        print("Could not get accessibility reference for '\(win.ownerName)'.")
        throw ExitCode.failure
    }

    let srcVisible = visibleFrameInCG(src)
    let dstVisible = visibleFrameInCG(dst)
    moveWindow(axWin, from: srcVisible, to: dstVisible, windowBounds: win.bounds)
    raiseWindow(axWin, pid: win.ownerPID)

    print("Pulled '\(win.ownerName)' to \(dst == primaryScreen() ? "primary" : "secondary") display.")
}

// MARK: - Swap foremost windows

func swapForemost(primary: NSScreen, secondary: NSScreen) throws {
    let allWindows = getVisibleWindows()
    let onPrimary = windowsOnScreen(primary, from: allWindows)
    let onSecondary = windowsOnScreen(secondary, from: allWindows)

    guard let primaryWin = onPrimary.first else {
        print("No windows on primary display to swap.")
        throw ExitCode.failure
    }
    guard let secondaryWin = onSecondary.first else {
        print("No windows on secondary display to swap.")
        throw ExitCode.failure
    }

    guard let axPrimary = axWindowForInfo(primaryWin) else {
        print("Could not get accessibility reference for primary window (\(primaryWin.ownerName)).")
        throw ExitCode.failure
    }
    guard let axSecondary = axWindowForInfo(secondaryWin) else {
        print("Could not get accessibility reference for secondary window (\(secondaryWin.ownerName)).")
        throw ExitCode.failure
    }

    let primaryVisible = visibleFrameInCG(primary)
    let secondaryVisible = visibleFrameInCG(secondary)

    // Move primary window → secondary screen, then secondary → primary
    moveWindow(axPrimary, from: primaryVisible, to: secondaryVisible, windowBounds: primaryWin.bounds)
    moveWindow(axSecondary, from: secondaryVisible, to: primaryVisible, windowBounds: secondaryWin.bounds)

    // Raise both windows to the front of their new screens
    raiseWindow(axSecondary, pid: secondaryWin.ownerPID)
    raiseWindow(axPrimary, pid: primaryWin.ownerPID)

    print("Swapped '\(primaryWin.ownerName)' (→ secondary) and '\(secondaryWin.ownerName)' (→ primary).")
}
