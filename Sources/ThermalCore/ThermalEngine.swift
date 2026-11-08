// ThermalEngine.swift
// センサーの束ね役。アプリと CLI の両方から使う唯一の入口。
//
//   Apple Silicon : IOHID センサーハブ (温度) + SMC (ファン, フォールバック温度)
//   Intel         : SMC (温度・ファン)
//   共通          : ProcessInfo.thermalState (OS のサーマルプレッシャー), ps (高負荷プロセス)

import Foundation

public struct ThermalSnapshot: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var sensors: [SensorReading]
    public var fans: [FanReading]
    public var pressure: SystemThermalPressure
    public var topProcesses: [ProcessLoad]
    public var representative: Double?
    public var level: ThermalLevel
    public var isAppleSilicon: Bool
    public var sourceDescription: String

    public static let empty = ThermalSnapshot(
        timestamp: .distantPast, sensors: [], fans: [], pressure: .nominal, topProcesses: [],
        representative: nil, level: .cool, isAppleSilicon: true, sourceDescription: "未取得"
    )

    /// カテゴリ別の最大温度。
    public func maxTemperature(in category: SensorCategory) -> Double? {
        sensors.filter { $0.category == category }.map(\.celsius).max()
    }

    /// カテゴリ別にまとめたセンサー一覧 (表示用)。
    public var groupedSensors: [(SensorCategory, [SensorReading])] {
        let groups = Dictionary(grouping: sensors, by: \.category)
        return groups.keys.sorted { $0.sortOrder < $1.sortOrder }.map { ($0, groups[$0]!.sorted { $0.celsius > $1.celsius }) }
    }
}

public final class ThermalEngine {
    public let isAppleSilicon: Bool
    public private(set) var thresholds: ThermalThresholds
    private var previousLevel: ThermalLevel = .cool

    #if canImport(IOKit)
    private let smc: SMC?
    private let hid: HIDSensors?
    private let fanController: FanController?
    #endif

    public init(thresholds: ThermalThresholds? = nil) {
        #if arch(arm64)
        isAppleSilicon = true
        #else
        isAppleSilicon = false
        #endif
        self.thresholds = thresholds ?? (isAppleSilicon ? .appleSilicon : .intel)

        #if canImport(IOKit)
        smc = try? SMC()
        hid = isAppleSilicon ? HIDSensors() : nil
        fanController = smc.map { FanController(smc: $0) }
        #endif
    }

    public func updateThresholds(_ t: ThermalThresholds) {
        thresholds = t
    }

    #if canImport(IOKit)
    public var fans: FanController? { fanController }
    public var smcConnection: SMC? { smc }
    #endif

    /// 現在の OS サーマルプレッシャー。
    public static func currentPressure() -> SystemThermalPressure {
        #if os(macOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
        #else
        return .nominal
        #endif
    }

    /// 温度センサーを読む (IOHID → SMC の順にフォールバック)。
    public func readSensors() -> (readings: [SensorReading], source: String) {
        #if canImport(IOKit)
        if let hid {
            let hidReadings = hid.readAll().filter { !SensorNaming.isNoise($0.name) }
            if !hidReadings.isEmpty {
                return (Self.uniquelyIdentified(hidReadings.map { ($0.name, $0.celsius) }), "IOHID センサーハブ")
            }
        }
        if let smc {
            let keys = isAppleSilicon ? SensorNaming.appleSiliconSMCTemperatureKeys : SensorNaming.intelTemperatureKeys
            var readings: [SensorReading] = []
            for key in keys {
                guard let v = try? smc.readDouble(key), v > 0, v < 150 else { continue }
                readings.append(SensorReading(rawName: key, celsius: v))
            }
            if !readings.isEmpty { return (readings, "AppleSMC") }
        }
        return ([], "センサー未検出 (仮想マシン?)")
        #else
        return ([], "非 macOS")
        #endif
    }

    /// 同名センサーに連番を振って ID を一意にする ("gas gauge battery" → "gas gauge battery#2" ...)。
    /// ラベルにも番号を付けて見分けられるようにする。
    static func uniquelyIdentified(_ raw: [(String, Double)]) -> [SensorReading] {
        var counts: [String: Int] = [:]
        for (name, _) in raw { counts[name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return raw.map { name, celsius in
            guard counts[name, default: 0] > 1 else { return SensorReading(rawName: name, celsius: celsius) }
            seen[name, default: 0] += 1
            let n = seen[name]!
            // 名前の末尾に番号を足して classify に通す ("gas gauge battery 2" → "バッテリー 2")
            return SensorReading(rawName: "\(name) \(n)", celsius: celsius, id: "\(name)#\(n)")
        }
    }

    public func readFans() -> [FanReading] {
        #if canImport(IOKit)
        return fanController?.readFans() ?? []
        #else
        return []
        #endif
    }

    /// 全部まとめて 1 スナップショット。
    public func snapshot(processLimit: Int = 5) -> ThermalSnapshot {
        let (sensors, source) = readSensors()
        let fans = readFans()
        let pressure = Self.currentPressure()
        let processes = ProcessSampler.topProcesses(limit: processLimit)
        let rep = ThermalPolicy.representativeTemperature(sensors)
        let level = ThermalPolicy.level(for: rep, previous: previousLevel, thresholds: thresholds, pressure: pressure)
        previousLevel = level
        return ThermalSnapshot(
            timestamp: Date(),
            sensors: sensors,
            fans: fans,
            pressure: pressure,
            topProcesses: processes,
            representative: rep,
            level: level,
            isAppleSilicon: isAppleSilicon,
            sourceDescription: source
        )
    }
}
