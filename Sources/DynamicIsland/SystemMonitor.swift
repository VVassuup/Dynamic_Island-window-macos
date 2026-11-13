import Foundation
import Darwin
import IOKit.ps

struct SystemSnapshot {
    var cpu: Double = 0
    var ram: Double = 0
    var ramUsed: UInt64 = 0
    var ramTotal: UInt64 = 0
    var disk: Double = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var diskName: String = "Macintosh HD"
    var down: Double = 0 // байт/с
    var up: Double = 0
    var battery: Int = -1
    var charging: Bool = false
    var threads: Int = ProcessInfo.processInfo.activeProcessorCount
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
}

/// Загрузка ЦП, ОЗУ, системного диска, сети и батареи — только системные API.
final class SystemMonitor {
    private var prevTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private var prevNet: (rx: UInt64, tx: UInt64, time: Date)?
    private var cpu: Double = 0

    func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        s.cpu = sampleCPU()
        sampleRAM(&s)
        sampleDisk(&s)
        sampleNet(&s)
        sampleBattery(&s)
        return s
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return cpu }
        let t = (user: UInt64(info.cpu_ticks.0), sys: UInt64(info.cpu_ticks.1),
                 idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        if let p = prevTicks {
            let du = Double(t.user &- p.user), ds = Double(t.sys &- p.sys)
            let di = Double(t.idle &- p.idle), dn = Double(t.nice &- p.nice)
            let total = du + ds + di + dn
            if total > 0 { cpu = min(100, max(0, (du + ds + dn) * 100 / total)) }
        }
        prevTicks = t
        return cpu
    }

    private func sampleRAM(_ s: inout SystemSnapshot) {
        s.ramTotal = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        // Как «Используется» в Мониторинге системы: активная + связанная + сжатая память
        let pages = UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        s.ramUsed = min(s.ramTotal, pages * UInt64(pageSize))
        s.ram = s.ramTotal > 0 ? Double(s.ramUsed) * 100 / Double(s.ramTotal) : 0
    }

    private func sampleDisk(_ s: inout SystemSnapshot) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeAvailableCapacityKey,
                                                        .volumeNameKey]) else { return }
        s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        s.diskFree = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        s.diskName = v.volumeName ?? "Macintosh HD"
        if s.diskTotal > 0 { s.disk = Double(s.diskTotal - s.diskFree) * 100 / Double(s.diskTotal) }
    }

    private func sampleNet(_ s: inout SystemSnapshot) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if !name.hasPrefix("lo") && !name.hasPrefix("utun") && !name.hasPrefix("awdl") && !name.hasPrefix("llw") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    rx += UInt64(d.ifi_ibytes)
                    tx += UInt64(d.ifi_obytes)
                }
            }
            p = ifa.ifa_next
        }
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.time)
            if dt > 0 {
                // счётчики 32-битные и могут переполняться — отрицательную разницу пропускаем
                s.down = rx >= prev.rx ? Double(rx - prev.rx) / dt : 0
                s.up = tx >= prev.tx ? Double(tx - prev.tx) / dt : 0
            }
        }
        prevNet = (rx, tx, now)
    }

    private func sampleBattery(_ s: inout SystemSnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (desc[kIOPSTypeKey] as? String) != kIOPSInternalBatteryType { continue }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            if cur >= 0 && max > 0 { s.battery = Int((Double(cur) * 100 / Double(max)).rounded()) }
            s.charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            break
        }
    }
}
