import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac running while agents work, lid closed included, without root:
/// an idle-sleep assertion plus IOPMrootDomain's clamshell-sleep switch (the one Amphetamine uses).
/// The switch is system-wide and outlives the process, so every exit path turns it back off.
@MainActor final class Power {
    private var assertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var keepDisplayAwake = false
    private var lidWasClosed = false
    private var builtInDisplay: CGDirectDisplayID?
    private var savedBrightness: (display: CGDirectDisplayID, value: Float)?
    private var powerSource: CFRunLoopSource?
    nonisolated(unsafe) private static var active = false

    init() {
        Self.setClamshellSleep(disabled: false)  // clear anything a crashed run left behind
        // Plugging or unplugging power can reset the switch; re-assert right away.
        powerSource = IOPSNotificationCreateRunLoopSource({ _ in
            if Power.active { Power.setClamshellSleep(disabled: true) }
        }, nil)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    var isActive: Bool { Self.active }

    func set(active: Bool, keepDisplayAwake: Bool = false) {
        let keepDisplayAwake = active && keepDisplayAwake
        guard active != Self.active || keepDisplayAwake != self.keepDisplayAwake else { return }
        lidWasClosed = false
        if keepDisplayAwake != self.keepDisplayAwake {
            self.keepDisplayAwake = keepDisplayAwake
            if keepDisplayAwake {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "StayVibe: agent working" as CFString, &displayAssertion)
                builtInDisplay = Self.builtInDisplay
            } else {
                restoreBrightness()
                IOPMAssertionRelease(displayAssertion)
                displayAssertion = 0
            }
        }
        if active != Self.active {
            Self.active = active
            log.notice("keep awake \(active ? "on" : "off", privacy: .public)")
            if active {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "StayVibe: agent working" as CFString, &assertion)
            } else {
                IOPMAssertionRelease(assertion)
                assertion = 0
            }
            Self.setClamshellSleep(disabled: active)
        }
        if active { tick() }
    }

    /// Sleep the display on lid close unless display wake is enabled; then dim the built-in panel.
    /// macOS may still disconnect that panel on lid close, independently of these assertions.
    func tick() {
        guard Self.active else { return }
        Self.setClamshellSleep(disabled: true)
        let closed = Self.lidClosed
        defer { lidWasClosed = closed }
        guard keepDisplayAwake else {
            if closed, !lidWasClosed, !Self.onlineDisplays.contains(where: { CGDisplayIsBuiltin($0) == 0 }) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                try? process.run()
            }
            return
        }
        if closed {
            guard let display = builtInDisplay ?? Self.builtInDisplay else { return }
            if savedBrightness == nil {
                guard let value = DisplayBrightness.get(display) else { return }
                savedBrightness = (display, value)
            }
            _ = DisplayBrightness.set(display, 0.01)
        } else {
            restoreBrightness()
            builtInDisplay = Self.builtInDisplay
        }
    }

    private func restoreBrightness() {
        guard let savedBrightness, DisplayBrightness.set(savedBrightness.display, savedBrightness.value) else { return }
        self.savedBrightness = nil
    }

    nonisolated static func setClamshellSleep(disabled: Bool) {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(root, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return }
        var input: UInt64 = disabled ? 1 : 0
        IOConnectCallScalarMethod(connection, UInt32(kPMSetClamshellSleepState), &input, 1, nil, nil)
        IOServiceClose(connection)
    }

    // MARK: - Machine state

    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        onlineDisplays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static var onlineDisplays: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Battery percentage while running on battery; nil on AC or without a battery.
    static var batteryLevel: Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPMBatteryPowerKey else { return nil }
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return list.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .compactMap { $0[kIOPSCurrentCapacityKey] as? Int }
            .first
    }
}

/// DisplayServices also supports built-in displays on Apple silicon. Load it optionally
/// so an unavailable private API leaves sleep prevention working without brightness control.
@MainActor private enum DisplayBrightness {
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        guard unsafeBitCast(symbol, to: Get.self)(display, &value) == kIOReturnSuccess else { return nil }
        return value
    }

    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let library, let symbol = dlsym(library, "DisplayServicesSetBrightness") else { return false }
        return unsafeBitCast(symbol, to: Set.self)(display, value) == kIOReturnSuccess
    }
}
