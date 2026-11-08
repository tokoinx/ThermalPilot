// ThermalPolicy.swift
// 「今どれくらい熱いか」を判定し、ユーザーに勧める行動を決める純粋ロジック。
// IOKit に依存しないので Linux 上でもユニットテストできる。

import Foundation

/// 熱レベル。メニューバーのアイコン色・通知・自動アクションの基準になる。
public enum ThermalLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case cool = 0      // 快適
    case warm = 1      // 温かい (作業中なら普通)
    case hot = 2       // 熱い。冷却アクションを勧める
    case critical = 3  // 危険域。サーマルスロットリング中の可能性

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .cool: return "快適"
        case .warm: return "ほんのり"
        case .hot: return "アツい"
        case .critical: return "危険"
        }
    }

    /// SF Symbols 名 (メニューバー表示用)
    public var symbolName: String {
        switch self {
        case .cool: return "thermometer.low"
        case .warm: return "thermometer.medium"
        case .hot: return "thermometer.high"
        case .critical: return "flame.fill"
        }
    }

    /// 遊び心のある一言
    public var mood: String {
        switch self {
        case .cool: return "❄️ ひんやり快調。今日もいい日。"
        case .warm: return "☕️ 体温くらい。ちょうどいい。"
        case .hot: return "🔥 そろそろ一服させましょう。"
        case .critical: return "🚨 サウナ状態。すぐ冷やして！"
        }
    }
}

/// 温度しきい値 (℃)。ユーザー設定で変更可能。
public struct ThermalThresholds: Sendable, Codable, Equatable {
    public var warm: Double
    public var hot: Double
    public var critical: Double
    /// ヒステリシス: レベルを下げる時はこの幅だけ下回ってから (通知のバタつき防止)
    public var hysteresis: Double

    public init(warm: Double = 60, hot: Double = 80, critical: Double = 95, hysteresis: Double = 4) {
        self.warm = warm
        self.hot = hot
        self.critical = critical
        self.hysteresis = hysteresis
    }

    /// Apple Silicon 向けの既定値。M シリーズはダイ温度 100℃ 超まで動作を許容するので、
    /// Intel より高めに設定する (FanBar / smctl も Tp* 系の上限を高めに取っている)。
    public static let appleSilicon = ThermalThresholds(warm: 65, hot: 85, critical: 100, hysteresis: 4)
    /// Intel 向けの既定値。
    public static let intel = ThermalThresholds(warm: 60, hot: 80, critical: 95, hysteresis: 4)
}

/// macOS の ProcessInfo.ThermalState に相当する値 (Foundation 依存を切るための写し)。
public enum SystemThermalPressure: Int, Sendable, Codable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public var label: String {
        switch self {
        case .nominal: return "通常"
        case .fair: return "やや高め"
        case .serious: return "高い (性能制限中)"
        case .critical: return "危険 (強い制限中)"
        }
    }
}

public enum ThermalPolicy {
    /// 代表温度: CPU カテゴリの最大値。CPU が無ければ全体の最大値。
    public static func representativeTemperature(_ readings: [SensorReading]) -> Double? {
        let cpu = readings.filter { $0.category == .cpu }.map(\.celsius)
        if let m = cpu.max() { return m }
        return readings.map(\.celsius).max()
    }

    /// しきい値だけで決めた素のレベル (ヒステリシスなし)。
    public static func rawLevel(for temperature: Double, thresholds t: ThermalThresholds) -> ThermalLevel {
        if temperature >= t.critical { return .critical }
        if temperature >= t.hot { return .hot }
        if temperature >= t.warm { return .warm }
        return .cool
    }

    /// 前回レベルを考慮したレベル判定。上がる時は即、下がる時はヒステリシス分だけ余裕を見る。
    /// さらに OS のサーマルプレッシャーが serious/critical なら、温度に関わらず最低 hot/critical に引き上げる。
    public static func level(
        for temperature: Double?,
        previous: ThermalLevel,
        thresholds t: ThermalThresholds,
        pressure: SystemThermalPressure = .nominal
    ) -> ThermalLevel {
        var level: ThermalLevel
        if let temperature {
            let raw = rawLevel(for: temperature, thresholds: t)
            if raw >= previous {
                level = raw
            } else {
                // 下げ判定: 前のレベルの下限 - ヒステリシス を下回ったら下げる
                let lowerBound: Double
                switch previous {
                case .critical: lowerBound = t.critical
                case .hot: lowerBound = t.hot
                case .warm: lowerBound = t.warm
                case .cool: lowerBound = -Double.infinity
                }
                level = temperature < lowerBound - t.hysteresis ? raw : previous
            }
        } else {
            level = .cool
        }

        switch pressure {
        case .critical: level = max(level, .critical)
        case .serious: level = max(level, .hot)
        default: break
        }
        return level
    }

    /// レベルに応じた行動の提案。
    public static func advice(for level: ThermalLevel, topProcess: ProcessLoad?) -> [String] {
        switch level {
        case .cool:
            return ["いまは何もしなくて大丈夫。"]
        case .warm:
            var tips = ["机の上の通気を確保 (背面・側面の吸気口を塞がない)。"]
            if let p = topProcess, p.cpuPercent > 50 {
                tips.append("\(p.name) が CPU \(Int(p.cpuPercent))% 使用中。意図した処理か確認を。")
            }
            return tips
        case .hot:
            var tips: [String] = []
            if let p = topProcess, p.cpuPercent > 30 {
                tips.append("\(p.name) (CPU \(Int(p.cpuPercent))%) を一時停止・終了すると一番効きます。")
            }
            tips.append("Safari/Chrome の動画タブ・未使用の Electron アプリを閉じる。")
            tips.append("低電力モードをオンにすると数分で 5〜10℃ 下がることが多い。")
            tips.append("膝の上や布団の上で使っているなら、硬い机へ。")
            return tips
        case .critical:
            return [
                "重い処理を今すぐ中断・保存を。macOS がクロックを落として自衛しています。",
                "低電力モードをオン。外部ディスプレイや充電器を一時的に外すのも有効。",
                "それでも下がらなければ、ファンの異音・吸気口のホコリ詰まりを疑ってください。",
            ]
        }
    }
}

/// プロセスの CPU 負荷 (ProcessSampler が生成)。
public struct ProcessLoad: Sendable, Equatable, Identifiable, Codable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double

    public init(pid: Int32, name: String, cpuPercent: Double) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
    }
}

/// ファンカーブ: 温度 → 目標 RPM の折れ線補間。thermalctl の `curve` サブコマンドで使う。
public struct FanCurve: Sendable, Codable, Equatable {
    public struct Point: Sendable, Codable, Equatable {
        public var celsius: Double
        public var rpm: Double
        public init(celsius: Double, rpm: Double) { self.celsius = celsius; self.rpm = rpm }
    }

    public var points: [Point]

    public init(points: [Point]) {
        self.points = points.sorted { $0.celsius < $1.celsius }
    }

    /// 「静かめ」既定カーブ。実機の最小/最大 RPM で clamp して使うこと。
    public static let balanced = FanCurve(points: [
        .init(celsius: 50, rpm: 0),
        .init(celsius: 65, rpm: 2200),
        .init(celsius: 80, rpm: 4000),
        .init(celsius: 95, rpm: 6500),
    ])

    public func rpm(at celsius: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if celsius <= first.celsius { return first.rpm }
        if celsius >= last.celsius { return last.rpm }
        for (a, b) in zip(points, points.dropFirst()) where celsius >= a.celsius && celsius <= b.celsius {
            let span = b.celsius - a.celsius
            if span <= 0 { return b.rpm }
            let t = (celsius - a.celsius) / span
            return a.rpm + (b.rpm - a.rpm) * t
        }
        return last.rpm
    }
}

/// 表示用フォーマッタ。
public enum ThermalFormat {
    public static func celsius(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value else { return "--°" }
        return String(format: "%.\(fractionDigits)f°", value)
    }

    public static func rpm(_ value: Double?) -> String {
        guard let value else { return "-- rpm" }
        return "\(Int(value.rounded())) rpm"
    }
}
