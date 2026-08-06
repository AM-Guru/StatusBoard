#if os(macOS)
import Foundation
import Darwin

/// Samples the Mac's vitals and publishes them through the bridge every few
/// seconds, so every device gets live system graphs with zero setup:
///
///   mac.cpu        CPU busy %              (+ mac.cpu.history)
///   mac.memory     memory pressure %       (+ mac.memory.history)
///   mac.disk       root volume used %      (+ mac.disk.history)
///   mac.net.in     download KB/s           (+ mac.net.in.history)
///   mac.net.out    upload KB/s             (+ mac.net.out.history)
///   mac.uptime     "3d 14h" text
@MainActor
final class SystemMetricsPublisher {
    private weak var server: BridgeServer?
    private var task: Task<Void, Never>?

    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastNetBytes: (received: UInt64, sent: UInt64, at: Date)?

    init(server: BridgeServer) {
        self.server = server
    }

    func start(interval: Double = 5) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sampleAndPublish()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sampleAndPublish() {
        guard let server, server.isRunning, server.publishesSystemMetrics else { return }

        if let cpu = sampleCPUPercent() {
            push("mac.cpu", number: cpu, unit: "%", history: 240)
        }
        if let memory = sampleMemoryPercent() {
            push("mac.memory", number: memory, unit: "%", history: 240)
        }
        if let disk = sampleDiskUsedPercent() {
            push("mac.disk", number: disk, unit: "%", history: 60)
        }
        if let net = sampleNetworkKBps() {
            push("mac.net.in", number: net.received, unit: "KB/s", history: 240)
            push("mac.net.out", number: net.sent, unit: "KB/s", history: 240)
        }
        var uptime = BridgePushRequest(key: "mac.uptime")
        uptime.text = Self.format(uptime: ProcessInfo.processInfo.systemUptime)
        server.apply(uptime, quiet: true)
    }

    private func push(_ key: String, number: Double, unit: String, history: Int) {
        var request = BridgePushRequest(key: key)
        request.number = (number * 10).rounded() / 10
        request.unit = unit
        request.history = history
        server?.apply(request, quiet: true)
    }

    // MARK: - CPU

    private func sampleCPUPercent() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastCPUTicks = (busy, total) }
        guard let last = lastCPUTicks, total > last.total else { return nil }
        let deltaBusy = Double(busy - last.busy)
        let deltaTotal = Double(total - last.total)
        guard deltaTotal > 0 else { return nil }
        return min(100, max(0, deltaBusy / deltaTotal * 100))
    }

    // MARK: - Memory

    private func sampleMemoryPercent() -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count)
                    + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(100, max(0, used / total * 100))
    }

    // MARK: - Disk

    private func sampleDiskUsedPercent() -> Double? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = (attributes[.systemSize] as? NSNumber)?.doubleValue,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.doubleValue,
              total > 0 else { return nil }
        return min(100, max(0, (total - free) / total * 100))
    }

    // MARK: - Network

    private func sampleNetworkKBps() -> (received: Double, sent: Double)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor = addresses
        while let current = cursor {
            let interface = current.pointee
            if interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let dataPointer = interface.ifa_data {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("lo") {
                    let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                    received &+= UInt64(data.ifi_ibytes)
                    sent &+= UInt64(data.ifi_obytes)
                }
            }
            cursor = interface.ifa_next
        }

        let now = Date()
        defer { lastNetBytes = (received, sent, now) }
        guard let last = lastNetBytes else { return nil }
        let elapsed = now.timeIntervalSince(last.at)
        // Counters are 32-bit on some interfaces; skip a sample on wraparound.
        guard elapsed > 0, received >= last.received, sent >= last.sent else { return nil }
        return (Double(received - last.received) / elapsed / 1024,
                Double(sent - last.sent) / elapsed / 1024)
    }

    // MARK: - Uptime

    static func format(uptime: TimeInterval) -> String {
        let totalMinutes = Int(uptime) / 60
        let days = totalMinutes / 1440
        let hours = totalMinutes % 1440 / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
#endif
