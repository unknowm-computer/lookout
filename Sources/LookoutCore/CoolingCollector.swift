import CSMC
import Darwin
import Foundation

public enum CoolingHardware {
    public static var isM1ProMacBook: Bool {
        #if arch(arm64)
        let brand = string("machdep.cpu.brand_string")
        return brand == "Apple M1 Pro" && ["MacBookPro18,1", "MacBookPro18,3"].contains(string("hw.model"))
        #else
        return false
        #endif
    }
    private static func string(_ key: String) -> String {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &bytes, &length, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public enum CoolingError: Error { case unsupported, unavailable, writeFailed(Int32), invalidSensors, externalController }

/// The sampler owns this collector's lifetime independently of other metrics.
protocol CoolingSampling {
    func reset()
    func sample(uptime: Double, force: Bool) throws -> CoolingReading
}

extension CoolingCollector: CoolingSampling {}

/// Confined to MetricSampler's actor, or the helper's serial queue. No global sensor enumeration.
public final class CoolingCollector {
    private var connection: UInt32 = 0
    private var cpuKeys: [String]?
    private var gpuKeys: [String]?
    private var cached: CoolingReading?
    private var band = CoolingTemperatureBand.normal
    public init() {}
    deinit { lookout_smc_close(connection) }
    public func reset() {
        cached = nil; band = .normal; cpuKeys = nil; gpuKeys = nil
        lookout_smc_close(connection); connection = 0
    }
    public func sample(uptime: Double = ProcessInfo.processInfo.systemUptime, force: Bool = false) throws -> CoolingReading {
        guard CoolingHardware.isM1ProMacBook else { throw CoolingError.unsupported }
        if !force, let cached, uptime >= cached.uptime, uptime - cached.uptime < 5 { return cached }
        if connection == 0, lookout_smc_open(&connection) != 0 { throw CoolingError.unavailable }
        // Documented by the M1 sensor mapping in Stats. These are thermal zones, not physical core counts.
        if cpuKeys == nil || gpuKeys == nil {
            cpuKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"].filter { temperature($0) != nil }
            gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"].filter { temperature($0) != nil }
        }
        if cpuKeys?.isEmpty == true { cpuKeys = nil }
        if gpuKeys?.isEmpty == true { gpuKeys = nil }
        let cpuValues = (cpuKeys ?? []).compactMap { temperature($0) }
        let gpuValues = (gpuKeys ?? []).compactMap { temperature($0) }
        let cpu = cpuValues.max(), gpu = gpuValues.max()
        let complete = cpuValues.count == cpuKeys?.count && gpuValues.count == gpuKeys?.count
        guard let highest = [cpu, gpu].compactMap({ $0 }).max() else { cached = nil; throw CoolingError.invalidSensors }
        let rawCount = number("FNum") ?? 0
        let count = rawCount.isFinite && (0...2).contains(rawCount) ? Int(rawCount) : 0
        var fans: [CoolingFan] = []
        if (1...2).contains(count) {
            for id in 0..<count {
                if let rpm = number("F\(id)Ac"), rpm.isFinite, (0...12000).contains(rpm) {
                    let mode = number("F\(id)Md") ?? number("F\(id)md")
                    fans.append(CoolingFan(id: id, rpm: rpm, minimum: number("F\(id)Mn") ?? 0,
                                           maximum: number("F\(id)Mx") ?? 0, target: number("F\(id)Tg"),
                                           automatic: mode.flatMap { [0.0, 1, 3].contains($0) ? ($0 == 0 || $0 == 3) : nil }))
                }
            }
        }
        band = band.updating(temperature: highest)
        let valid = complete && cpu != nil && gpu != nil && count == 2 && fans.count == 2 && fans.allSatisfy { $0.hasValidRange && $0.automatic != nil }
        let result = CoolingReading(cpu: cpu, gpu: gpu, fans: fans, band: band, uptime: uptime, canControl: valid)
        cached = result
        return result
    }
    public func setTargets(_ targets: [Int: Double]) throws {
        guard geteuid() == 0, CoolingHardware.isM1ProMacBook else { throw CoolingError.unsupported }
        let reading = try sample()
        guard reading.canControl, targets.count == 2 else { throw CoolingError.invalidSensors }
        for fan in reading.fans {
            guard let target = targets[fan.id], target.isFinite,
                  (fan.minimum...fan.maximum).contains(target) else { throw CoolingError.invalidSensors }
        }
        for fan in reading.fans {
            let result = lookout_smc_fan_target(connection, Int32(fan.id), targets[fan.id]!)
            guard result == 0 else { throw CoolingError.writeFailed(result) }
        }
    }
    /// Try both supported fans even if one fails. The caller must own control or handle an explicit reset.
    public func restoreSystem() throws {
        guard geteuid() == 0, CoolingHardware.isM1ProMacBook else { throw CoolingError.unsupported }
        if connection == 0, lookout_smc_open(&connection) != 0 { throw CoolingError.unavailable }
        if number("FNum") == nil {
            lookout_smc_close(connection); connection = 0
            if lookout_smc_open(&connection) != 0 { throw CoolingError.unavailable }
        }
        var failure: Int32 = 0
        for id in 0..<2 {
            let result = lookout_smc_fan_auto(connection, Int32(id))
            if result != 0 { failure = result }
        }
        if failure == 0 { reset() }
        if failure != 0 { throw CoolingError.writeFailed(failure) }
    }
    private func temperature(_ key: String) -> Double? {
        guard let value = number(key), value.isFinite, (1...120).contains(value) else { return nil }
        return value
    }
    private func number(_ key: String) -> Double? {
        var type: UInt32 = 0, size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        guard lookout_smc_read(connection, key, &type, &size, &bytes) == 0 else { return nil }
        switch type {
        case 0x666c7420 where size == 4: // flt , native-endian IEEE754
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case 0x73703738 where size == 2: // sp78, big-endian signed fixed point
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case 0x66706532 where size == 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case 0x75693820 where size == 1: return Double(bytes[0])
        case 0x75693136 where size == 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default: return nil
        }
    }
}
