import AppKit
import IOBluetooth
import IOKit

/// Battery levels of connected Bluetooth accessories - a Magic Keyboard,
/// Mouse or Trackpad, AirPods - plus a nudge in the island when one runs low.
///
/// Two sources, both read on demand and neither needing a permission of its
/// own beyond the Bluetooth one the app already asks for:
///
/// - Apple's HID accessories publish `BatteryPercent` on their
///   `AppleDeviceManagementHIDEventService` in the IORegistry. Public IOKit.
/// - AirPods and Beats report per-bud levels through `IOBluetoothDevice`
///   properties that are not in the SDK. Checked with `responds(to:)` before
///   every read, so a macOS that drops them costs the row, not a crash.
///
/// Read when the island opens and at the moments a level is worth news - a
/// device connecting, the Mac waking or unlocking. Nothing polls: a keyboard
/// takes days to go flat, and one of those moments always comes first.
@MainActor
@Observable
final class DeviceBatteries {
    static let shared = DeviceBatteries()

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let percent: Int
        let symbol: String
        /// "L 80% · R 75% · Case 40%" for earbuds that report per bud.
        var detail: String?
    }

    private(set) var devices: [Device] = []
    /// Lowest threshold already announced per device, so each crossing is
    /// news once rather than on every unlock.
    private var announced: [String: Int] = [:]

    private init() {}

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeviceBatteries.shared.check(after: 5) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DeviceBatteries.shared.check(after: 2) }
        }
        check(after: 6)
    }

    func refresh() {
        devices = Self.read(bluetooth: BluetoothWatch.shared.authorized)
    }

    /// Re-reads, then announces any device that has dropped to 20% or 10%.
    func check(after seconds: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            refresh()
            for device in devices {
                if device.percent > 30 { announced[device.id] = nil; continue }
                guard let threshold = [20, 10].last(where: { device.percent <= $0 }),
                      threshold < (announced[device.id] ?? 101)
                else { continue }
                announced[device.id] = threshold
                guard Settings.shared.bluetooth else { continue }
                HUD.shared.show(.utility(symbol: "battery.25percent", title: "\(device.name) \(device.percent)%",
                                         detail: "Charge it soon"), for: 3)
                return   // one at a time; the next unlock brings the next
            }
        }
    }

    /// A connected device's level, for the "Connected" card.
    func percent(forName name: String) -> Int? {
        devices.first { $0.name == name }?.percent
    }

    // MARK: - Reading

    nonisolated private static func read(bluetooth: Bool) -> [Device] {
        var found: [Device] = []
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS {
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let percent = property(service, "BatteryPercent") as? Int,
                      let name = property(service, "Product") as? String
                else { continue }
                let id = property(service, "DeviceAddress") as? String ?? name
                guard !found.contains(where: { $0.id == id }) else { continue }
                found.append(Device(id: id, name: name, percent: percent, symbol: symbol(forProduct: name)))
            }
            IOObjectRelease(iterator)
        }
        // IOBluetooth raises the permission prompt on first use, so it is only
        // touched once Bluetooth has been granted.
        guard bluetooth else { return found }
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] where device.isConnected() {
            let levels = ["batteryPercentLeft", "batteryPercentRight", "batteryPercentCase", "batteryPercentSingle"]
                .map { key -> Int? in
                    guard device.responds(to: NSSelectorFromString(key)),
                          let value = (device.value(forKey: key) as? NSNumber)?.intValue, value > 0, value <= 100
                    else { return nil }
                    return value
                }
            let (left, right, box, single) = (levels[0], levels[1], levels[2], levels[3])
            guard let lowest = [left, right].compactMap({ $0 }).min() ?? single,
                  let name = device.name,
                  let address = device.addressString,
                  !found.contains(where: { $0.id.caseInsensitiveCompare(address) == .orderedSame
                      || $0.id.replacingOccurrences(of: "-", with: ":").caseInsensitiveCompare(address) == .orderedSame })
            else { continue }
            let parts = [("L", left), ("R", right), ("Case", box)].compactMap { label, value in value.map { "\(label) \($0)%" } }
            found.append(Device(id: address, name: name, percent: lowest,
                                symbol: left != nil ? "airpods" : "headphones",
                                detail: parts.count > 1 ? parts.joined(separator: " · ") : nil))
        }
        return found.sorted { $0.percent < $1.percent }
    }

    nonisolated private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    nonisolated private static func symbol(forProduct name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("mouse") { return "magicmouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if lower.contains("keyboard") { return "keyboard" }
        return "battery.75percent"
    }
}
