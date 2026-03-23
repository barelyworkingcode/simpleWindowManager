import ArgumentParser
import AppKit
import CoreAudio
import CoreGraphics

@main
struct SWM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swm",
        abstract: "Simple window manager for multi-display setups.",
        subcommands: [CyclePrimary.self, CycleSecondary.self, SwapForemost.self, PushToSecondary.self, PullToPrimary.self, ToggleFillCenter.self, ShowKeys.self, MuteMicrophone.self]
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
        if NSScreen.screens.count == 1 && isStageManagerEnabled() {
            try cycleStages()
        } else if NSScreen.screens.count == 1 {
            try cycleWindows(on: nil)
        } else {
            try cycleWindows(on: primaryScreen())
        }
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

struct MuteMicrophone: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute",
        abstract: "Toggle the default microphone mute state."
    )

    func run() throws {
        try toggleMicMute()
    }
}

struct ShowKeys: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Show a floating overlay of all Karabiner Hyper key shortcuts."
    )

    func run() throws {
        MainActor.assumeIsolated {
            showKeysOverlay()
        }
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

// MARK: - Stage Manager detection

func isStageManagerEnabled() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "com.apple.WindowManager", "GloballyEnabled"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "1"
    } catch {
        return false
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

func cycleWindows(on screen: NSScreen?) throws {
    let allWindows = getVisibleWindows()
    let onScreen: [WindowInfo]
    if let screen = screen {
        onScreen = windowsOnScreen(screen, from: allWindows)
    } else {
        onScreen = allWindows
    }

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
    let displayLabel: String
    if let screen = screen {
        displayLabel = screen == primaryScreen() ? "primary" : "secondary"
    } else {
        displayLabel = "single"
    }
    print("Raised '\(bottomWindow.ownerName)' to the top on \(displayLabel) display.")
}

/// Cycle through Stage Manager stages using round-robin.
/// Enumerates all regular apps with real windows, sorts them deterministically,
/// finds the currently active app, and raises the next one in the list.
func cycleStages() throws {
    // Find all regular apps that have at least one real window
    let allApps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated }

    var appsWithWindows: [(pid: pid_t, name: String)] = []
    for app in allApps {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement],
              !axWindows.isEmpty else { continue }

        let hasRealWindow = axWindows.contains { axWin in
            guard let size = getWindowSize(axWin) else { return false }
            return size.width >= 200 && size.height >= 200
        }
        guard hasRealWindow else { continue }

        appsWithWindows.append((pid: app.processIdentifier, name: app.localizedName ?? "unknown"))
    }

    // Sort by name for deterministic cycling order
    appsWithWindows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    guard appsWithWindows.count > 1 else {
        if appsWithWindows.isEmpty {
            print("No windows found on this display.")
        } else {
            print("Only one window/stage on this display, nothing to cycle.")
        }
        return
    }

    // Find the currently active app and pick the next one
    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let currentIdx = appsWithWindows.firstIndex(where: { $0.pid == frontPID }) ?? 0
    let nextIdx = (currentIdx + 1) % appsWithWindows.count
    let target = appsWithWindows[nextIdx]

    // Raise the app's main window to bring its stage forward
    let appElement = AXUIElementCreateApplication(target.pid)
    var windowsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
    guard let axWindows = windowsRef as? [AXUIElement], let mainWindow = axWindows.first else {
        print("Could not get window for '\(target.name)'.")
        throw ExitCode.failure
    }

    raiseWindow(mainWindow, pid: target.pid)
    print("Raised '\(target.name)' to the top on stage display.")
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

// MARK: - Keys overlay

func parseKarabinerDescriptions() -> [String] {
    let path = (NSString("~/.config/karabiner/karabiner.json").expandingTildeInPath)
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profiles = json["profiles"] as? [[String: Any]] else {
        return []
    }

    // Use the selected profile, or fall back to the first
    let profile = profiles.first(where: { $0["selected"] as? Bool == true }) ?? profiles.first
    guard let rules = (profile?["complex_modifications"] as? [String: Any])?["rules"] as? [[String: Any]] else {
        return []
    }

    var descriptions: [String] = []
    for rule in rules {
        if let desc = rule["description"] as? String, desc.contains("Hyper+") {
            descriptions.append(desc)
        }
    }
    return descriptions
}

class KeysOverlayDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let descriptions: [String]
    var panel: NSPanel?
    var monitor: Any?

    init(descriptions: [String]) {
        self.descriptions = descriptions
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]

        // Build the text content
        let title = "Hyper Key Shortcuts"
        let separator = String(repeating: "─", count: 40)
        var lines: [String] = [title, separator]
        for desc in descriptions {
            // Descriptions are like "Hyper+Q: Rotate apps on primary display"
            // Split on first ": " to format as columns
            if let colonRange = desc.range(of: ": ") {
                let key = String(desc[desc.startIndex..<colonRange.lowerBound])
                let action = String(desc[colonRange.upperBound...])
                let padded = key.padding(toLength: 16, withPad: " ", startingAt: 0)
                lines.append("\(padded) \(action)")
            } else {
                lines.append(desc)
            }
        }
        lines.append("")
        lines.append("Press any key to dismiss")

        let text = lines.joined(separator: "\n")

        // Create attributed string
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let titleFont = NSFont.monospacedSystemFont(ofSize: 20, weight: .bold)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = 4

        let attrString = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paraStyle
        ])
        // Style the title
        let titleRange = (text as NSString).range(of: title)
        attrString.addAttribute(.font, value: titleFont, range: titleRange)
        // Style the dismiss hint
        let hintRange = (text as NSString).range(of: "Press any key to dismiss")
        attrString.addAttribute(.foregroundColor, value: NSColor.lightGray, range: hintRange)

        // Measure text size — use a huge width so nothing wraps, then size the panel to fit
        let noWrapSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let textRect = attrString.boundingRect(with: noWrapSize, options: [.usesLineFragmentOrigin, .usesFontLeading])

        let padding: CGFloat = 40
        let panelWidth = ceil(textRect.width) + padding * 2
        let panelHeight = ceil(textRect.height) + padding * 2

        // Center on screen
        let panelX = screen.frame.origin.x + (screen.frame.width - panelWidth) / 2
        let panelY = screen.frame.origin.y + (screen.frame.height - panelHeight) / 2
        let panelFrame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 0.1, alpha: 0.92)
        panel.hasShadow = true

        // Round corners
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 16
        panel.contentView?.layer?.masksToBounds = true

        // Add text view
        let textView = NSTextView(frame: NSRect(x: padding, y: padding,
                                                 width: panelWidth - padding * 2,
                                                 height: panelHeight - padding * 2))
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.textStorage?.setAttributedString(attrString)

        panel.contentView?.addSubview(textView)
        panel.orderFrontRegardless()
        self.panel = panel

        // Monitor for any key press to dismiss
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.dismiss()
            return nil
        }

        // Also dismiss on mouse click
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismiss()
            return nil
        }

        // Activate so we can receive key events
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    @MainActor func dismiss() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        panel?.close()
        NSApp.terminate(nil)
    }
}

@MainActor func showKeysOverlay() {
    let descriptions = parseKarabinerDescriptions()
    if descriptions.isEmpty {
        print("No Hyper key shortcuts found in Karabiner config.")
        return
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = KeysOverlayDelegate(descriptions: descriptions)
    app.delegate = delegate
    app.run()
}

// MARK: - Microphone mute toggle

func toggleMicMute() throws {
    // Get the default input device
    var deviceID = AudioDeviceID(0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID
    )
    guard status == noErr, deviceID != kAudioDeviceUnknown else {
        print("No default input device found.")
        throw ExitCode.failure
    }

    // Read the current mute state
    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    var isMuted: UInt32 = 0
    status = AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &isMuted)
    guard status == noErr else {
        print("Could not read microphone mute state (error \(status)).")
        throw ExitCode.failure
    }

    // Toggle
    var newMute: UInt32 = isMuted == 0 ? 1 : 0
    status = AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, muteSize, &newMute)
    guard status == noErr else {
        print("Could not set microphone mute state (error \(status)).")
        throw ExitCode.failure
    }

    print(newMute == 1 ? "Microphone muted." : "Microphone unmuted.")
}
