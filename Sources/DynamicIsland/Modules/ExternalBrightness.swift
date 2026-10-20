import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Brightness of an external monitor, over DDC/CI.
///
/// `DisplayServices` - what the brightness keys and `Utilities.brightness` use -
/// only ever reaches the built-in panel, which is why the island's brightness
/// slider does nothing for a desk monitor. Every monitor with a brightness menu of
/// its own can be driven over DDC/CI instead: a small I2C message on the display
/// cable, the same channel the monitor's own buttons talk to.
///
/// On Apple Silicon that channel is `IOAVService`, which is private, so the three
/// symbols are resolved at runtime and the whole feature hides itself if they ever
/// move - the treatment brightness and the screen lock already get.
///
/// Nothing runs at rest. Levels are read when the island opens with a monitor
/// attached, and written when you drag. There is no watcher: a monitor's own
/// buttons can change brightness behind our back, and re-reading on open is
/// cheaper than any way of noticing.
///
/// Idea borrowed from MonitorControl, which solved this first. The DDC/CI framing
/// below is from the standard rather than from its code.
@MainActor
@Observable
final class ExternalBrightness {
    static let shared = ExternalBrightness()

    struct Display: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        /// 0...1. What was last read or written, never a live reading.
        var level: Float
        /// Which DDC channel this monitor was paired with.
        let channel: Int
    }

    private(set) var displays: [Display] = []

    /// True once the private symbols resolved and at least one external monitor
    /// has a channel to talk down.
    var available: Bool { Self.write != nil && !displays.isEmpty }

    private init() {}

    // MARK: - The private channel

    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private nonisolated(unsafe) static let iokit: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY
    )
    private nonisolated static let createService: CreateService? = iokit
        .flatMap { dlsym($0, "IOAVServiceCreateWithService") }
        .map { unsafeBitCast($0, to: CreateService.self) }
    private nonisolated static let write: TransferI2C? = iokit
        .flatMap { dlsym($0, "IOAVServiceWriteI2C") }
        .map { unsafeBitCast($0, to: TransferI2C.self) }
    private nonisolated static let read: TransferI2C? = iokit
        .flatMap { dlsym($0, "IOAVServiceReadI2C") }
        .map { unsafeBitCast($0, to: TransferI2C.self) }

    /// DDC/CI over I2C: the display answers at 0x6E, the host calls itself 0x51,
    /// and brightness is VCP feature 0x10. `IOAVService` takes the 7-bit address
    /// (0x6E >> 1) and the source byte as the register offset, so the buffer we
    /// hand it starts at the length byte.
    private nonisolated static let chipAddress: UInt32 = 0x37
    private nonisolated static let sourceAddress: UInt32 = 0x51
    private nonisolated static let displayAddress: UInt8 = 0x6E
    private nonisolated static let brightnessVCP: UInt8 = 0x10

    /// One `IOAVService` per external monitor, in registry order.
    private var services: [CFTypeRef] = []
    /// Reported maximum per display, once a monitor has answered a read. Monitors
    /// that never answer are driven against the standard's own 100.
    private var maximum: [CGDirectDisplayID: UInt16] = [:]

    // MARK: - Finding the monitors

    /// Rebuilt on a display change, which AppKit already posts. One IORegistry
    /// walk, no polling.
    ///
    /// Monitors are paired with channels by order rather than by identity: the
    /// service carries no serial number, so two identical monitors could in
    /// principle be crossed. With one attached - the common case, and the only one
    /// this was verified against - the pairing is unambiguous.
    func refresh() {
        guard Settings.shared.externalBrightness, Self.write != nil else {
            services = []
            displays = []
            return
        }
        services = Self.externalServices()
        let external = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            return (id, screen.localizedName)
        }
        // Only as many monitors as there are channels to reach them on.
        displays = external.prefix(services.count).enumerated().map { channel, pair in
            Display(id: pair.0, name: pair.1, level: Self.stored(pair.0) ?? 0.5, channel: channel)
        }
        // Which of those channels actually carries I2C is only knowable by trying,
        // and the answer prunes the list. Off the main thread, so a monitor that
        // takes its time does not hold up a display change.
        readLevels()
    }

    private nonisolated static func externalServices() -> [CFTypeRef] {
        guard let create = createService else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [CFTypeRef] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            // The built-in panel has a service of its own, and a brightness write
            // to that one does nothing at best.
            let location = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            guard location == "External" else { continue }
            guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            found.append(service)
        }
        return found
    }

    // MARK: - Reading and writing

    /// Remembered per display, because a monitor that refuses to be read still
    /// needs its slider to start where it was left.
    private static func stored(_ id: CGDirectDisplayID) -> Float? {
        (UserDefaults.standard.object(forKey: "ddcBrightness.\(id)") as? Double).map { Float($0) }
    }

    func setLevel(_ value: Float, for display: Display) {
        guard let index = displays.firstIndex(where: { $0.id == display.id }),
              services.indices.contains(display.channel)
        else { return }
        let level = min(max(value, 0), 1)
        displays[index].level = level
        UserDefaults.standard.set(Double(level), forKey: "ddcBrightness.\(display.id)")

        let ceiling = maximum[display.id] ?? 100
        let raw = UInt16((level * Float(ceiling)).rounded())
        let service = services[display.channel]
        // Off the main thread: an I2C write talks to hardware, and a slider drag
        // makes a great many of them.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.setVCP(service, Self.brightnessVCP, raw)
        }
    }

    /// Asks each monitor where its brightness is, and whether it can be talked to
    /// at all.
    ///
    /// A DDC read is a write, a wait and then a read, so it runs off the main
    /// thread - a monitor slow to answer would otherwise stall the panel opening.
    /// Two different failures come back from it, and they mean opposite things:
    ///
    /// - The transfer itself is refused. The cable, the adapter or the OS is not
    ///   carrying I2C - measured on this Mac's external port, which answers
    ///   `0xE0114000` to every transfer. Writing brightness there can never work,
    ///   so the slider is removed rather than left sitting at a level it is not
    ///   setting.
    /// - The transfer works and no reply arrives. Plenty of monitors take DDC
    ///   writes and answer no reads, which is fine: the remembered level stands and
    ///   the slider still moves the monitor.
    func readLevels() {
        guard Settings.shared.externalBrightness, Self.write != nil, !displays.isEmpty else { return }
        let pairs = displays.map { ($0.id, $0.channel) }
        let channels = services
        DispatchQueue.global(qos: .utility).async {
            var readings: [(CGDirectDisplayID, UInt16, UInt16)] = []
            var refused: [CGDirectDisplayID] = []
            for (id, channel) in pairs where channels.indices.contains(channel) {
                switch Self.getVCP(channels[channel], Self.brightnessVCP) {
                case .refused: refused.append(id)
                case .silent: break
                case .value(let current, let ceiling): readings.append((id, current, ceiling))
                }
            }
            guard !readings.isEmpty || !refused.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.shared.apply(readings, refused: refused) }
            }
        }
    }

    private func apply(_ readings: [(CGDirectDisplayID, UInt16, UInt16)], refused: [CGDirectDisplayID]) {
        displays.removeAll { refused.contains($0.id) }
        for (id, current, ceiling) in readings {
            guard ceiling > 0, let index = displays.firstIndex(where: { $0.id == id }) else { continue }
            maximum[id] = ceiling
            let level = min(Float(current) / Float(ceiling), 1)
            displays[index].level = level
            UserDefaults.standard.set(Double(level), forKey: "ddcBrightness.\(id)")
        }
    }

    // MARK: - DDC/CI framing

    private nonisolated static func setVCP(_ service: CFTypeRef, _ vcp: UInt8, _ value: UInt16) {
        guard let write else { return }
        // Length with the standard's high bit, "set VCP feature", the feature, its
        // value big-endian, then the checksum.
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet[0 ..< 5], seed: displayAddress ^ UInt8(sourceAddress))
        // The bus wants a moment before it is written to, and the write is made
        // twice: DDC has no acknowledgement, and a single packet is dropped often
        // enough on a real cable to make a slider feel broken.
        for _ in 0 ..< 2 {
            usleep(10_000)
            _ = packet.withUnsafeMutableBufferPointer { buffer in
                write(service, chipAddress, sourceAddress, buffer.baseAddress!, UInt32(buffer.count))
            }
        }
    }

    /// What came back from asking a monitor for a feature.
    enum Answer {
        /// The bus refused the transfer: no I2C reaches this display at all.
        case refused
        /// The transfer went out and nothing came back, which is common and fine.
        case silent
        case value(current: UInt16, ceiling: UInt16)
    }

    /// Current and maximum, or which kind of nothing happened.
    ///
    /// Four tries with a pause between. DDC is best-effort with no handshake, so a
    /// monitor that is asleep or busy simply says nothing, and four silences in a
    /// row is the normal shape of "this monitor does not do DDC reads".
    private nonisolated static func getVCP(_ service: CFTypeRef, _ vcp: UInt8) -> Answer {
        guard let write, let read else { return .refused }
        // "Get VCP feature" carries no value, and its checksum is seeded with the
        // display's address alone - the one asymmetry in the framing, and the
        // reason an otherwise correct-looking request gets no answer at all.
        var request: [UInt8] = [0x82, 0x01, vcp, 0]
        request[3] = checksum(request[0 ..< 3], seed: displayAddress)

        for _ in 0 ..< 4 {
            var sent: Int32 = 0
            for _ in 0 ..< 2 {
                usleep(10_000)
                sent = request.withUnsafeMutableBufferPointer { buffer in
                    write(service, chipAddress, sourceAddress, buffer.baseAddress!, UInt32(buffer.count))
                }
            }
            // Not "no answer yet" - the bus itself said no, and it will say no to
            // every write as well. Retrying is pointless and so is the slider.
            guard sent == 0 else { return .refused }
            // The standard asks for 40ms before the reply is fetched.
            usleep(50_000)
            // Eleven bytes: the display's address, the length, the reply opcode, a
            // result code, the feature, its type, then the maximum and the current
            // value, and a checksum. Read from offset zero - a reply is not a
            // register at our own address.
            var reply = [UInt8](repeating: 0, count: 11)
            let got = reply.withUnsafeMutableBufferPointer { buffer in
                read(service, chipAddress, 0, buffer.baseAddress!, UInt32(buffer.count))
            }
            // A garbled read looks exactly like a valid one until the checksum is
            // tested, which is why the values are only trusted after it.
            guard got == 0, reply[2] == 0x02, reply[4] == vcp,
                  checksum(reply[0 ..< 10], seed: 0x50) == reply[10]
            else {
                usleep(20_000)
                continue
            }
            let ceiling = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            guard ceiling > 0 else { continue }
            return .value(current: current, ceiling: ceiling)
        }
        return .silent
    }

    /// XOR of every byte, seeded with the addresses that travel as I2C addressing
    /// rather than as data: the display's for a request the display answers, the
    /// host's own for a reply addressed back to us.
    private nonisolated static func checksum(_ bytes: ArraySlice<UInt8>, seed: UInt8) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }
}
