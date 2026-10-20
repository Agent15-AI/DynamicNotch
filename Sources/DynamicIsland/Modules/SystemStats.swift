import Darwin
import Foundation
import IOKit

/// CPU, GPU, memory and network throughput.
///
/// **Sampling runs only while the island is open.** This is the feature that put
/// Atoll's stats daemon on the battery-drain lists, and the reason is always the
/// same: a timer that keeps polling when nobody is looking. `start()` is called
/// when the island expands and `stop()` when it collapses, so a closed island
/// costs exactly nothing.
@MainActor
@Observable
final class SystemStats {
    static let shared = SystemStats()

    private(set) var cpu: Double = 0        // 0...1
    private(set) var gpu: Double?           // nil when no GPU counter is exposed
    private(set) var memory: Double = 0     // 0...1, footprint against physical
    private(set) var memoryUsed = ""        // the same figure in GB, already formatted
    private(set) var disk: Double = 0       // 0...1 used on the boot volume
    private(set) var diskUsed = ""          // "374/494"; the unit is in the label
    private(set) var swap: Double = 0       // 0...1 of swap in use
    private(set) var swapUsed = ""          // formatted, empty when none is used
    private(set) var down: Double = 0       // bytes/sec
    private(set) var up: Double = 0
    /// Cumulative interface counters. These are since the interface came up, so
    /// they are reported as "since boot" rather than accumulated here - nothing
    /// has to run while the island is shut for them to stay right.
    private(set) var downTotal: UInt64 = 0
    private(set) var upTotal: UInt64 = 0

    private var timer: Timer?
    private var previousCPU: (user: Double, system: Double, idle: Double, nice: Double)?
    private var previousNet: (down: UInt64, up: UInt64, at: Date)?

    private init() {}

    func start() {
        guard Settings.shared.stats, timer == nil else { return }
        // Read once per open rather than on every tick. Free space does not move
        // in the seconds an island is up, and the capacity query is the most
        // expensive read in this file.
        readDisk()
        sample()
        // One second: fast enough to feel live, slow enough to stay invisible in
        // the power budget for the seconds an island is actually open.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousCPU = nil
        previousNet = nil
    }

    private func sample() {
        readCPU()
        readMemory()
        readSwap()
        Sensors.shared.sample()
        readGPU()
        readNetwork()
    }

    // MARK: - CPU

    private func readCPU() {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let current = (
            user: Double(info.cpu_ticks.0),
            system: Double(info.cpu_ticks.1),
            idle: Double(info.cpu_ticks.2),
            nice: Double(info.cpu_ticks.3)
        )
        defer { previousCPU = current }
        guard let previous = previousCPU else { return }

        // Ticks are cumulative since boot, so only the delta means anything.
        let used = (current.user - previous.user)
            + (current.system - previous.system)
            + (current.nice - previous.nice)
        let idle = current.idle - previous.idle
        let total = used + idle
        guard total > 0 else { return }
        cpu = min(max(used / total, 0), 1)
    }

    // MARK: - Memory

    private func readMemory() {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // Page size is fetched rather than read from the global, which Swift 6
        // treats as shared mutable state.
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)
        // Footprint the way Activity Monitor counts it: what cannot be freed.
        let used = (Double(stats.active_count) + Double(stats.wire_count)
            + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return }
        memory = min(max(used / total, 0), 1)
        // Gigabytes, not a bare percentage. "70%" of an unknown total is not a
        // number anyone can act on; "11.2 GB" is.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB]
        formatter.isAdaptive = false
        memoryUsed = formatter.string(fromByteCount: Int64(used))
    }

    // MARK: - Swap

    /// `vm.swapusage` is one sysctl, no parsing of `vm_stat` output.
    private func readSwap() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, usage.xsu_total > 0
        else { swap = 0; swapUsed = ""; return }
        swap = min(max(Double(usage.xsu_used) / Double(usage.xsu_total), 0), 1)
        swapUsed = usage.xsu_used == 0
            ? "None"
            : ByteCountFormatter.string(fromByteCount: Int64(usage.xsu_used), countStyle: .memory)
    }

    // MARK: - GPU

    private func readGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { gpu = nil; return }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            // Apple Silicon and Intel expose different key names for the same idea.
            let value = (stats["Device Utilization %"] ?? stats["GPU Core Utilization"]) as? NSNumber
            if let value {
                let fraction = value.doubleValue > 1 ? value.doubleValue / 100 : value.doubleValue
                best = max(best ?? 0, min(max(fraction, 0), 1))
            }
        }
        gpu = best
    }

    // MARK: - Disk

    /// Meter and number both read the same way: how full the volume is.
    ///
    /// This used to show free space alone - "120 GB" with a meter three-quarters
    /// full, which reads as *used* at a glance and is the opposite number. Used
    /// against total says the same thing twice instead of contradicting itself.
    /// Re-read after something frees space. The sample timer deliberately does
    /// not touch this - capacity is the most expensive read in the file and does
    /// not move on its own - so a deletion has to say when it has.
    func refreshDisk() { readDisk() }

    private func readDisk() {
        let url = URL(fileURLWithPath: "/")
        // Important-usage capacity, not raw free space: it is what the Finder
        // reports, because it counts what macOS would purge if pushed.
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ),
            let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity, total > 0
        else { return }
        disk = min(max(1 - Double(free) / Double(total), 0), 1)
        // ponytail: formatted here rather than by `ByteCountFormatter`, which is
        // the one thing it cannot do - it picks a unit per number, so a 374 GB
        // used against a 494 GB volume came out "374 GB/494.38 GB", and past a
        // terabyte the two halves stop sharing a unit altogether.
        //
        // The unit is named once, by the tile's label. Carried inline it made
        // this the only value in the strip too wide for its share of the row, so
        // it wrapped and dropped its meter half a line below every other one -
        // the whole strip read as broken over three characters. In the label it
        // sits with the dimmer text where a unit belongs, and the numbers stay
        // the only thing at full weight.
        let gigabyte = 1_000_000_000.0
        let used = Int((Double(Int64(total) - free) / gigabyte).rounded())
        diskUsed = "\(used)/\(Int((Double(total) / gigabyte).rounded()))"
    }

    // MARK: - Network

    private func readNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: interface.ifa_name)
            // Skip loopback and virtual interfaces, or local traffic inflates it.
            guard name.hasPrefix("en") || name.hasPrefix("pdp") else { continue }
            guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }

        downTotal = received
        upTotal = sent

        let now = Date()
        defer { previousNet = (received, sent, now) }
        guard let previous = previousNet else { return }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return }
        // Counters wrap and reset; a negative delta means treat it as zero.
        down = max(0, Double(received &- previous.down)) / elapsed
        up = max(0, Double(sent &- previous.up)) / elapsed
    }

    /// Compact throughput, e.g. `1.2 MB/s`.
    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
        return value >= 100 || index == 0
            ? String(format: "%.0f %@/s", value, units[index])
            : String(format: "%.1f %@/s", value, units[index])
    }
}
