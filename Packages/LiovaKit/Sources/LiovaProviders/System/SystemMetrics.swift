import Darwin
import Foundation
import IOKit

/// One reading of the Mac's load, each value 0…1.
public struct SystemSample: Equatable, Sendable {
    public var cpu: Double
    public var memory: Double
    /// Nil when the GPU doesn't report utilization.
    public var gpu: Double?

    public init(cpu: Double, memory: Double, gpu: Double?) {
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
    }
}

/// Reads CPU, memory and GPU load with public kernel and IOKit interfaces.
///
/// CPU load is a difference between two tick counters, so the first `sample()` after
/// creation returns 0 for CPU. Costs a few microseconds per call; callers decide how often
/// (Liova samples once a second, and only while the System page is on screen).
public final class SystemMetricsReader: @unchecked Sendable {
    /// Guarded by being used from one place at a time (the sampler's queue).
    private var previousTicks: (busy: UInt64, total: UInt64)?

    public init() {}

    public func sample() -> SystemSample {
        SystemSample(cpu: cpuLoad(), memory: Self.memoryUsage(), gpu: Self.gpuUtilization())
    }

    // MARK: - CPU

    private func cpuLoad() -> Double {
        guard let ticks = Self.cpuTicks() else { return 0 }
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return 0 }
        return Self.load(from: previous, to: ticks)
    }

    /// Busy share of the ticks between two readings. Pure, so it's unit-tested.
    static func load(from old: (busy: UInt64, total: UInt64), to new: (busy: UInt64, total: UInt64)) -> Double {
        guard new.total > old.total, new.busy >= old.busy else { return 0 }
        return min(max(Double(new.busy - old.busy) / Double(new.total - old.total), 0), 1)
    }

    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (busy: user + system + nice, total: user + system + idle + nice)
    }

    // MARK: - Memory

    /// "Memory used" as Activity Monitor counts it: app memory + wired + compressed.
    static func memoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Double(getpagesize())
        let appMemory = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (appMemory + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(max(used / total, 0), 1) : 0
    }

    // MARK: - GPU

    /// Device utilization reported by the GPU driver in the IOKit registry, if any.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any],
                let value = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
            else { continue }
            best = max(best ?? 0, value.doubleValue / 100)
        }
        return best.map { min(max($0, 0), 1) }
    }
}
