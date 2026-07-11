//
//  SystemStatsView.swift
//  boringNotch
//
//  Device status tab: CPU usage, RAM usage, network throughput and real-time
//  power draw. CPU/RAM come from mach host statistics, network speed from
//  getifaddrs deltas, and power from the SMC "PSTR" key (total system power,
//  Apple Silicon) with a battery-registry fallback. Sampling only runs while
//  the tab is visible.
//

import AppKit
import IOKit
import SwiftUI

// MARK: - SMC (minimal read-only client for float keys)

private final class SMC {
    static let shared = SMC()

    private var conn: io_connect_t = 0

    private struct ParamStruct {
        var key: UInt32 = 0
        var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0
        var versReserved: UInt8 = 0
        var versRelease: UInt16 = 0
        var versPad: UInt16 = 0 // matches C alignment: pLimitData starts at offset 12
        var pLimitVersion: UInt16 = 0, pLimitLength: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
        var keyInfoDataSize: UInt32 = 0
        var keyInfoDataType: UInt32 = 0
        var keyInfoDataAttributes: UInt8 = 0
        var keyInfoPad: (UInt8, UInt8, UInt8) = (0, 0, 0) // keyInfo struct pads to 12 bytes
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
    }

    private func call(_ input: inout ParamStruct) -> ParamStruct? {
        guard conn != 0 else { return nil }
        var output = ParamStruct()
        var outSize = MemoryLayout<ParamStruct>.stride
        let result = IOConnectCallStructMethod(
            conn, 2, // kSMCHandleYPCEvent
            &input, MemoryLayout<ParamStruct>.stride,
            &output, &outSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    /// Read a 4-char SMC key holding a float ("flt " type), e.g. "PSTR".
    func readFloat(_ key: String) -> Float? {
        let keyCode = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        var info = ParamStruct()
        info.key = keyCode
        info.data8 = 9 // kSMCGetKeyInfo
        guard let infoOut = call(&info), infoOut.keyInfoDataSize == 4 else { return nil }

        var read = ParamStruct()
        read.key = keyCode
        read.keyInfoDataSize = infoOut.keyInfoDataSize
        read.data8 = 5 // kSMCReadKey
        guard let out = call(&read) else { return nil }
        let b = out.bytes
        let bits = UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24
        return Float(bitPattern: bits)
    }

    /// Enumerate all SMC key names starting with the given prefix.
    /// Sensor key names differ per chip generation, so discover instead of hardcoding.
    func keys(withPrefix prefix: String) -> [String] {
        var countReq = ParamStruct()
        countReq.key = "#KEY".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        countReq.keyInfoDataSize = 4
        countReq.data8 = 5 // kSMCReadKey
        guard let countOut = call(&countReq) else { return [] }
        let b = countOut.bytes
        let total = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)

        var found: [String] = []
        for index in 0..<total {
            var req = ParamStruct()
            req.data8 = 8 // kSMCGetKeyFromIndex
            req.data32 = index
            guard let out = call(&req) else { continue }
            let name = String(bytes: [UInt8(out.key >> 24 & 0xFF), UInt8(out.key >> 16 & 0xFF),
                                      UInt8(out.key >> 8 & 0xFF), UInt8(out.key & 0xFF)],
                              encoding: .ascii) ?? ""
            if name.hasPrefix(prefix) {
                found.append(name)
            }
        }
        return found
    }
}

// MARK: - Manager

@MainActor
final class SystemStatsManager: ObservableObject {
    static let shared = SystemStatsManager()

    @Published private(set) var cpuUsage: Double = 0          // 0...1
    @Published private(set) var ramUsed: Double = 0           // bytes
    @Published private(set) var ramTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var downSpeed: Double = 0         // bytes/s
    @Published private(set) var upSpeed: Double = 0           // bytes/s
    @Published private(set) var powerWatts: Double?           // nil = unavailable
    @Published private(set) var gpuUsage: Double?             // 0...1, nil = unavailable
    @Published private(set) var cpuTemp: Double?              // °C
    @Published private(set) var gpuTemp: Double?              // °C

    private var timer: Timer?
    private var prevCPUTicks: (busy: Double, total: Double)?
    private var prevNet: (rx: UInt64, tx: UInt64, at: Date)?
    private var cpuTempKeys: [String]?
    private var gpuTempKeys: [String]?

    private init() {}

    func start() {
        guard timer == nil else { return }
        if cpuTempKeys == nil {
            // ponytail: one-time synchronous SMC key scan (~100ms), move off-main if it ever janks
            cpuTempKeys = SMC.shared.keys(withPrefix: "Tp") // CPU sensors (Apple Silicon)
            gpuTempKeys = SMC.shared.keys(withPrefix: "Tg") // GPU sensors
        }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        prevCPUTicks = nil
        prevNet = nil
    }

    private func sample() {
        sampleCPU()
        sampleRAM()
        sampleNetwork()
        samplePower()
        sampleGPU()
        sampleTemps()
    }

    private func sampleGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else {
            gpuUsage = nil
            return
        }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let utilization = stats["Device Utilization %"] as? Int {
                gpuUsage = Double(utilization) / 100
                return
            }
        }
        gpuUsage = nil
    }

    private func sampleTemps() {
        func average(_ keys: [String]?) -> Double? {
            let values = (keys ?? []).compactMap { SMC.shared.readFloat($0) }
                .filter { $0 > 10 && $0 < 120 } // drop dead/implausible sensors
            guard !values.isEmpty else { return nil }
            return Double(values.reduce(0, +)) / Double(values.count)
        }
        cpuTemp = average(cpuTempKeys)
        gpuTemp = average(gpuTempKeys)
    }

    private func sampleCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let user = Double(info.cpu_ticks.0), sys = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2), nice = Double(info.cpu_ticks.3)
        let busy = user + sys + nice
        let total = busy + idle
        if let prev = prevCPUTicks, total > prev.total {
            cpuUsage = min(1, max(0, (busy - prev.busy) / (total - prev.total)))
        }
        prevCPUTicks = (busy, total)
    }

    private func sampleRAM() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let pageSize = Double(vm_kernel_page_size)
        // Roughly Activity Monitor's "Memory Used": app + wired + compressed
        ramUsed = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
    }

    private func sampleNetwork() {
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let first = ifaddrs else { return }
        defer { freeifaddrs(ifaddrs) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            // ponytail: only en* (Wi-Fi/Ethernet); utun/VPN would double-count
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: ifa.pointee.ifa_name).hasPrefix("en"),
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            rx &+= UInt64(data.pointee.ifi_ibytes)
            tx &+= UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0, rx >= prev.rx, tx >= prev.tx {
                downSpeed = Double(rx - prev.rx) / dt
                upSpeed = Double(tx - prev.tx) / dt
            }
        }
        prevNet = (rx, tx, now)
    }

    private func samplePower() {
        // Total system power (Apple Silicon). Fallback: battery drain/charge rate.
        if let watts = SMC.shared.readFloat("PSTR"), watts > 0 {
            powerWatts = Double(watts)
            return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { powerWatts = nil; return }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        if let mA = prop("Amperage"), let mV = prop("Voltage") {
            // Amperage is signed (negative = draining); Int wraps it unsigned on some systems
            let amps = Double(Int64(truncatingIfNeeded: Int64(mA))) / 1000
            powerWatts = abs(amps) * (Double(mV) / 1000)
        } else {
            powerWatts = nil
        }
    }
}

// MARK: - View

struct SystemStatsView: View {
    @ObservedObject private var manager = SystemStatsManager.shared

    private func tempString(_ celsius: Double?) -> String {
        celsius.map { String(format: "%.0f°C", $0) } ?? "--"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(
                    icon: "cpu",
                    title: "CPU",
                    value: String(format: "%.0f%%", manager.cpuUsage * 100),
                    detail: nil,
                    fraction: manager.cpuUsage
                )
                StatTile(
                    icon: "cpu.fill",
                    title: "GPU",
                    value: manager.gpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "--",
                    detail: nil,
                    fraction: manager.gpuUsage
                )
                StatTile(
                    icon: "memorychip",
                    title: "RAM",
                    value: String(format: "%.1f GB", manager.ramUsed / 1_073_741_824),
                    detail: String(format: "of %.0f GB", manager.ramTotal / 1_073_741_824),
                    fraction: manager.ramUsed / manager.ramTotal
                )
            }
            HStack(spacing: 10) {
                StatTile(
                    icon: "network",
                    title: "Network",
                    value: "↓ " + speedString(manager.downSpeed),
                    detail: "↑ " + speedString(manager.upSpeed),
                    fraction: nil
                )
                StatTile(
                    icon: "thermometer.medium",
                    title: "Temp",
                    value: "CPU " + tempString(manager.cpuTemp),
                    detail: "GPU " + tempString(manager.gpuTemp),
                    fraction: nil
                )
                StatTile(
                    icon: "bolt.fill",
                    title: "Power",
                    value: manager.powerWatts.map { String(format: "%.1f W", $0) } ?? "--",
                    detail: nil,
                    fraction: nil
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.start() }
        .onDisappear { manager.stop() }
    }

    private func speedString(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576)
        }
        return String(format: "%.0f KB/s", bytesPerSec / 1024)
    }
}

private struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String?
    let fraction: Double? // shows a usage bar when present

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.gray)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: .secondarySystemFill))
                        Capsule()
                            .fill(fraction > 0.85 ? Color.red : Color.accentColor)
                            .frame(width: max(3, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
                .animation(.smooth(duration: 0.5), value: fraction)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .secondarySystemFill).opacity(0.5))
        )
    }
}
