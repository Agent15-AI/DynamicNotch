import Darwin
import Foundation
import IOKit

/// Temperature, in two layers.
///
/// `ProcessInfo.thermalState` is public, notification-driven and always right -
/// it is what macOS itself acts on when it decides to throttle. That is the
/// layer that is guaranteed to work, and it costs nothing: the system tells us
/// when it changes.
///
/// The actual degrees come from the HID temperature sensors, which is how every
/// Mac monitor reads them on Apple Silicon. Those symbols are not in the SDK, so
/// they are resolved at runtime and the whole thing degrades to "no reading"
/// rather than failing to build or crashing if Apple moves them.
///
/// Sampled only while the island is open, alongside the other stats.
@MainActor
@Observable
final class Sensors {
    static let shared = Sensors()

    private(set) var celsius: Double?
    private(set) var thermal: ProcessInfo.ThermalState = .nominal

    private init() {
        thermal = ProcessInfo.processInfo.thermalState
    }

    /// Event-driven, so this is live even while the island is shut.
    func start() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            MainActor.assumeIsolated { self?.thermal = state }
        }
    }

    var thermalLabel: String {
        switch thermal {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Throttling"
        @unknown default: "Normal"
        }
    }

    /// 0...1 for the meter. Thermal state is a four-step scale, so it maps to
    /// quarters when there is no reading in degrees to use instead.
    var fraction: Double {
        if let celsius {
            // 30 C idle to 100 C throttling covers the whole usable range.
            return min(max((celsius - 30) / 70, 0), 1)
        }
        switch thermal {
        case .nominal: return 0.25
        case .fair: return 0.5
        case .serious: return 0.75
        case .critical: return 1.0
        @unknown default: return 0.25
        }
    }

    var text: String {
        if let celsius { return "\(Int(celsius.rounded()))°" }
        return thermalLabel
    }

    /// Reads the hottest CPU sensor. Called from `SystemStats.sample()`, so it
    /// runs only while the island is open.
    func sample() {
        celsius = Self.hottestCPUSensor()
    }

    // MARK: - HID sensors

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventFloat = @convention(c) (AnyObject, Int32) -> Double

    /// Apple's vendor HID page, temperature sensor usage, and the temperature
    /// event type. Stable across every Apple Silicon Mac so far.
    private static let vendorPage = 0xff00
    private static let temperatureUsage = 5
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private static func hottestCPUSensor() -> Double? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        else { return nil }
        defer { dlclose(handle) }

        guard let createSym = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchSym = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSym = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySym = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSym = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSym = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return nil }

        let create = unsafeBitCast(createSym, to: CreateClient.self)
        let setMatching = unsafeBitCast(matchSym, to: SetMatching.self)
        let copyServices = unsafeBitCast(servicesSym, to: CopyServices.self)
        let copyProperty = unsafeBitCast(propertySym, to: CopyProperty.self)
        let copyEvent = unsafeBitCast(eventSym, to: CopyEvent.self)
        let floatValue = unsafeBitCast(floatSym, to: EventFloat.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        setMatching(client, [
            "PrimaryUsagePage": Self.vendorPage,
            "PrimaryUsage": Self.temperatureUsage,
        ] as CFDictionary)

        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return nil }

        var hottest: Double?
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String else { continue }
            // 47 sensors on an M4, and most of them answer a different
            // question: battery, NAND, enclosure. The die sensors are the ones
            // that mean "how hot is the chip" - named `PMU tdie<n>` on Apple
            // Silicon, `TCPU`/`CPU` on Intel.
            //
            // `tcal` is excluded on purpose. It reads a steady 51.8 and is a
            // calibration constant, not a temperature - taking the maximum
            // without excluding it pins the display at 52 degrees forever.
            let lowered = name.lowercased()
            guard !lowered.contains("tcal") else { continue }
            guard lowered.contains("tdie") || lowered.contains("cpu") else { continue }
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = floatValue(event, Self.temperatureField)
            // Disconnected sensors read zero, and nothing runs at 200 C.
            guard value > 1, value < 200 else { continue }
            hottest = max(hottest ?? 0, value)
        }
        return hottest
    }
}
