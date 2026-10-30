#if DEBUG
import ScreenCaptureKit
import SwiftUI

/// Captures the real menu bar window with sample data. Run through scripts/screenshot.sh.
/// The fixture shares the production Scene and never starts hooks, usage reads, or notifications.
@MainActor enum Snapshot {
    private static var suffix = "en"
    private static var backdrop: NSWindow?

    static func render(language code: String?) -> Never {
        guard let code, code == "en" || code == "zh" else {
            fail(Failure("Expected --snapshot en or --snapshot zh. Run scripts/screenshot.sh."))
        }
        guard Bundle.main.bundleIdentifier == "io.github.dvdsanyi.stayvibe.snapshot" else {
            fail(Failure("Use scripts/screenshot.sh so sample preferences stay isolated from the installed app."))
        }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        suffix = code
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        let model = AppModel.shared
        model.loadSample()
        model.settings.language = code == "en" ? .en : .zhHans
        model.settings.usageAgent = .codex
        SnapshotApp.main()
        exit(0)
    }

    static func capture() async {
        do {
            let item = try await statusItem()
            guard let screen = item.button?.window?.screen ?? NSScreen.main else { throw Failure("No screenshot display.") }
            prepareBackdrop(on: screen)
            // Let Launch Services finish initial activation before opening a transient system panel.
            try await Task.sleep(for: .milliseconds(500))
            try present(item)
            let window = try await panelWindow()
            try await Task.sleep(for: .milliseconds(600))
            let settings = CommandLine.arguments.contains("--snapshot-settings")
            if settings {
                NotificationCenter.default.post(name: Notification.Name("StayVibe.snapshot.showSettings"), object: nil)
                try await Task.sleep(for: .milliseconds(700))
            }
            guard let button = item.button else { throw Failure("No screenshot status item button.") }
            geometry(settings ? "settings" : "main", window)
            let image = try await image(of: window, statusButton: settings ? nil : button)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Failure("Could not encode the README image.")
            }
            try FileHandle.standardOutput.write(contentsOf: png)
            log("wrote \(settings ? "settings" : "screenshot")-\(suffix).png")
            item.expandedInterfaceSession?.cancel()
            NSApp.terminate(nil)
        } catch { fail(error) }
    }

    private static func statusItem() async throws -> NSStatusItem {
        let getter = NSSelectorFromString("statusItem")
        for _ in 0..<50 {
            for window in NSApp.windows {
                guard let root = window.contentView, statusButton(in: root) != nil,
                      window.responds(to: getter),
                      let item = window.perform(getter)?.takeUnretainedValue() as? NSStatusItem,
                      item.expandedInterfaceDelegate != nil else { continue }
                return item
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Could not find the screenshot app's own menu bar item.")
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.compactMap(statusButton).first
    }

    private static func present(_ item: NSStatusItem) throws {
        // macOS 27 no longer gives window-based status buttons a target/action. This DEBUG-only
        // fixture starts the system's real expanded session on its own item; it never recreates chrome.
        let selector = NSSelectorFromString("_beginExpandedInterfaceSession:")
        guard item.responds(to: selector), let implementation = item.method(for: selector),
              let method = class_getInstanceMethod(type(of: item), selector),
              let signature = method_getTypeEncoding(method), String(cString: signature) == "v24@0:8d16" else {
            throw Failure("This macOS version cannot automatically present the real menu bar screenshot window.")
        }
        typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
        unsafeBitCast(implementation, to: Begin.self)(item, selector, .greatestFiniteMagnitude)
    }

    private static func panelWindow() async throws -> NSWindow {
        for _ in 0..<50 {
            if let window = NSApp.windows.first(where: { $0 !== backdrop && $0.isVisible && $0.frame.height > 100 }) { return window }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("The system menu bar window did not open. Unlock the Mac and try again.")
    }

    /// A real white window gives the system material a predictable backdrop. Capturing only the
    /// popup in isolation makes ScreenCaptureKit flatten its glass against gray instead.
    private static func prepareBackdrop(on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .white
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        backdrop = window
    }

    private static func image(of window: NSWindow, statusButton: NSStatusBarButton?) async throws -> CGImage {
        guard window.isVisible else { throw Failure("The menu bar window closed before capture. Keep it open and retry.") }
        guard let identifier = CGWindowID(exactly: window.windowNumber) else { throw Failure("Invalid native window identifier.") }
        let content = try await SCShareableContent.currentProcess
        guard window.isVisible else { throw Failure("The menu bar window closed during capture.") }
        guard let source = content.windows.first(where: { $0.windowID == identifier }) else {
            throw Failure("The screenshot window is not available to ScreenCaptureKit.")
        }
        let config = SCScreenshotConfiguration()
        config.ignoreShadows = false
        config.showsCursor = false
        config.includeChildWindows = true
        config.displayIntent = .canonical
        let result = try await SCScreenshotManager.captureScreenshot(contentFilter: SCContentFilter(desktopIndependentWindow: source),
                                                                    configuration: config)
        guard let image = result.sdrImage else { throw Failure("ScreenCaptureKit returned no window image.") }
        guard let backdrop, let backdropID = CGWindowID(exactly: backdrop.windowNumber),
              let background = content.windows.first(where: { $0.windowID == backdropID }),
              let screenID = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == screenID.uint32Value }) else {
            throw Failure("No screenshot backdrop display.")
        }
        let scale = window.backingScaleFactor
        let marginX = (CGFloat(image.width) / scale - source.frame.width) / 2
        let marginY = (CGFloat(image.height) / scale - source.frame.height) / 2
        // Derive shadow padding from the system's own window capture rather than drawing or sizing it.
        let popupRect = source.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            .insetBy(dx: -marginX, dy: -marginY)
        config.sourceRect = statusButton == nil ? popupRect
            : CGRect(x: popupRect.minX, y: 0, width: popupRect.width, height: popupRect.maxY)
        config.width = Int((config.sourceRect.width * scale).rounded())
        config.height = Int((config.sourceRect.height * scale).rounded())
        guard window.isVisible else { throw Failure("The menu bar window closed during capture.") }
        let filter = SCContentFilter(display: display, including: [background, source])
        filter.includeMenuBar = false
        let baseRect = config.sourceRect
        let capture = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard window.isVisible, let base = capture.sdrImage else {
            throw Failure("The menu bar window closed during capture.")
        }
        guard let statusButton else { return base }
        guard let buttonWindow = statusButton.window, let screen = window.screen else {
            throw Failure("The status item has no display.")
        }
        let frame = buttonWindow.frame
        let buttonRect = buttonWindow.convertToScreen(statusButton.convert(statusButton.bounds, to: nil))
        let statusRect = CGRect(x: buttonRect.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                width: buttonRect.width, height: frame.height)
        guard statusRect.width > 0, statusRect.height > 0,
              CGRect(origin: .zero, size: display.frame.size).contains(statusRect) else {
            throw Failure("The status item has no on-screen frame.")
        }
        // Capture only our item's exact rectangle. Enabling the menu bar over the whole
        // image would also capture other apps' icons and the user's clock.
        filter.includeMenuBar = true
        config.sourceRect = statusRect
        config.width = Int((statusRect.width * scale).rounded())
        config.height = Int((statusRect.height * scale).rounded())
        config.ignoreShadows = true
        let statusCapture = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
        guard window.isVisible, let status = statusCapture.sdrImage,
              let leading = status.cropping(to: CGRect(x: 0, y: 0, width: 1, height: status.height)),
              let trailing = status.cropping(to: CGRect(x: status.width - 1, y: 0, width: 1, height: status.height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("Could not compose the isolated menu bar image.")
        }
        // Extend the captured empty edges; keep the real icon, panel and their positions unscaled.
        canvas.interpolationQuality = .none
        canvas.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let top = CGFloat(base.height - status.height)
        let itemX = (statusRect.minX - baseRect.minX) * scale
        let right = itemX + CGFloat(status.width)
        canvas.draw(leading, in: CGRect(x: 0, y: top, width: CGFloat(base.width), height: CGFloat(status.height)))
        canvas.draw(trailing, in: CGRect(x: right, y: top, width: max(0, CGFloat(base.width) - right),
                                        height: CGFloat(status.height)))
        canvas.draw(status, in: CGRect(x: itemX, y: top - statusRect.minY * scale,
                                      width: CGFloat(status.width), height: CGFloat(status.height)))
        guard let output = canvas.makeImage() else { throw Failure("Could not finish the README image.") }
        return output
    }

    private static func geometry(_ page: String, _ window: NSWindow) {
        log("\(page) frame=\(window.frame.size) content=\(window.contentLayoutRect.size) visible=\(window.isVisible)")
    }

    private static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("snapshot: \(message)\n".utf8))
    }

    private static func fail(_ error: Error) -> Never {
        log("failed: \(error as NSError)")
        exit(1)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

private struct SnapshotApp: App {
    @NSApplicationDelegateAdaptor(SnapshotDelegate.self) private var delegate
    var body: some Scene { StayVibeMenuBarScene() }
}

private final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await Snapshot.capture() }
    }
}
#endif
