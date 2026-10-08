import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac running while agents work, lid closed included, without root:
/// an idle-sleep assertion plus IOPMrootDomain's clamshell-sleep switch (the one Amphetamine uses).
/// The switch is system-wide and outlives the process, so every exit path turns it back off.
@MainActor final class Power {
    private var assertion: IOPMAssertionID = 0
    private var lidWasClosed = false
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

    func set(active: Bool) {
        guard active != Self.active else { return }
        Self.active = active
        log.notice("keep awake \(active ? "on" : "off", privacy: .public)")
        if active {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "StayVibe: agent working" as CFString, &assertion)
        } else {
            IOPMAssertionRelease(assertion)
        }
        Self.setClamshellSleep(disabled: active)
    }

    /// Called every couple of seconds: re-assert the switch, and dark the built-in screen on lid close.
    func tick() {
        guard Self.active else { lidWasClosed = false; return }
        Self.setClamshellSleep(disabled: true)
        let closed = Self.lidClosed
        if closed, !lidWasClosed, !Self.externalDisplayConnected {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        }
        lidWasClosed = closed
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

    static var externalDisplayConnected: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
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

    static var tooHot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }
}
