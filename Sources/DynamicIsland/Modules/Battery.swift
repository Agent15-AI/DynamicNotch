import Foundation
import IOKit
import IOKit.ps

/// Battery state from IOKit power-source notifications. Event-driven; IOKit
/// wakes us only when something actually changes.
@MainActor
@Observable
final class Battery {
    static let shared = Battery()

    private(set) var percent = 0
    private(set) var charging = false
    private(set) var pluggedIn = false
    private(set) var lowPower = false
    /// Set briefly after a plug/unplug so the island can show a live activity.
    private(set) var lastPlugChange: Date?
    /// Minutes until empty (or until full while charging). Nil while macOS is
    /// still working it out, which it reports as -1.
    private(set) var minutesRemaining: Int?
    private(set) var cycleCount: Int?
    /// Watts in or out right now. Negative while discharging is folded away -
    /// the sign is already carried by `pluggedIn`.
    private(set) var watts: Double?
    /// Maximum capacity as a percentage of the design capacity.
    private(set) var health: Int?

    private var source: CFRunLoopSource?
    /// The first read has nothing to compare against. Without this it counted as
    /// a plug change on every launch that started on mains power, which then ate
    /// the launch suppression and left the next real plug-in silent.
    private var didRead = false

    private init() {}

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let battery = Unmanaged<Battery>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in battery.read() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
        read()
    }

    private func read() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for entry in list {
            guard let info = IOPSGetPowerSourceDescription(blob, entry)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let wasPlugged = pluggedIn
            percent = Int((Double(current) / Double(max) * 100).rounded())
            charging = info[kIOPSIsChargingKey] as? Bool ?? false
            pluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if didRead, wasPlugged != pluggedIn { lastPlugChange = Date() }
            didRead = true
            lowPower = percent <= 20 && !pluggedIn

            let key = pluggedIn ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = info[key] as? Int ?? -1
            minutesRemaining = minutes > 0 ? minutes : nil

            readSmartBattery()
            return
        }
    }

    /// Cycle count and health come from the IORegistry, not IOPS. Read once per
    /// power-source change - these move on the order of days.
    private func readSmartBattery() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Int? {
            guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber else { return nil }
            return value.intValue
        }
        cycleCount = number("CycleCount")
        // Amperage is milliamps and signed; voltage is millivolts. Their product
        // is the only honest power figure available without an admin helper.
        if let milliamps = number("Amperage"), let millivolts = number("Voltage") {
            let value = abs(Double(milliamps)) * Double(millivolts) / 1_000_000
            watts = value > 0.05 ? value : nil
        } else {
            watts = nil
        }
        if let maximum = number("AppleRawMaxCapacity") ?? number("MaxCapacity"),
           let design = number("DesignCapacity"), design > 0 {
            health = Int((Double(maximum) / Double(design) * 100).rounded())
        }
    }

    /// Human-readable time remaining, or nil when macOS has not settled yet.
    var remainingText: String? {
        guard let minutesRemaining else { return nil }
        let hours = minutesRemaining / 60, minutes = minutesRemaining % 60
        let value = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
        return pluggedIn ? "\(value) to full" : "\(value) left"
    }
}
