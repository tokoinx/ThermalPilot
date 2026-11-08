// SensorNaming.swift
// 生のセンサー名 (IOHID "Product" や SMC キー) を、人間向けのラベルとカテゴリに落とす。
// Apple はセンサー名の公式マッピングを公開していないので、ここは各ツールが独自に決めている
// (macmon / Stats / FanBar も同様)。プラットフォーム非依存の純粋関数なのでテスト可能。

import Foundation

public enum SensorCategory: String, CaseIterable, Sendable, Codable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "メモリ"
    case storage = "SSD"
    case battery = "バッテリー"
    case power = "電源"
    case ambient = "筐体/周辺"
    case other = "その他"

    /// メニューの表示順
    public var sortOrder: Int {
        switch self {
        case .cpu: return 0
        case .gpu: return 1
        case .memory: return 2
        case .storage: return 3
        case .battery: return 4
        case .power: return 5
        case .ambient: return 6
        case .other: return 7
        }
    }
}

public struct SensorReading: Sendable, Equatable, Identifiable, Codable {
    /// 一意 ID。同名センサーが複数ある機種 ("gas gauge battery" ×6 など) があるので rawName とは別に持つ。
    public let id: String
    public let rawName: String
    public let label: String
    public let category: SensorCategory
    public let celsius: Double

    public init(rawName: String, celsius: Double, id: String? = nil) {
        self.rawName = rawName
        self.celsius = celsius
        self.id = id ?? rawName
        let (label, category) = SensorNaming.classify(rawName)
        self.label = label.trimmingCharacters(in: .whitespaces)
        self.category = category
    }
}

public enum SensorNaming {
    /// 生の名前 → (表示ラベル, カテゴリ)
    /// 名前の末尾の数字 ("PMU2 tdie7" → "7", "GPU MTR Temp Sensor4" → "4")。無ければ空文字。
    static func trailingNumber(_ raw: String) -> String {
        String(raw.reversed().prefix { $0.isNumber }.reversed())
    }

    /// 2 つ目の PMU ("PMU2 ...") なら " (PMU2)" を付ける。M1/M2 Pro・Max 系は PMU が 2 系統ある。
    private static func pmuSuffix(_ lower: String) -> String {
        lower.hasPrefix("pmu2") ? " (PMU2)" : ""
    }

    /// 実温度ではないセンサー (校正値など)。一覧から除外する。
    public static func isNoise(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("tcal")
    }

    public static func classify(_ raw: String) -> (String, SensorCategory) {
        let lower = raw.lowercased()
        let n = trailingNumber(raw)

        // ---- Apple Silicon の IOHID センサー名 (MacBook Pro M-series 実機で確認した名前を優先) ----
        if lower.contains("tdie") {
            // "PMU tdie1".."PMU2 tdie8": CPU ダイ温度。代表温度はここの最大値
            return ("CPU ダイ \(n)\(pmuSuffix(lower))", .cpu)
        }
        if lower.contains("tdev") {
            return ("SoC デバイス \(n)\(pmuSuffix(lower))", .cpu)
        }
        if lower.hasPrefix("pacc") {
            return ("P コア クラスタ \(n)", .cpu)          // Performance core cluster
        }
        if lower.hasPrefix("eacc") {
            return ("E コア クラスタ \(n)", .cpu)          // Efficiency core cluster
        }
        if lower.contains("pmgr soc") || lower.contains("soc mtr") || lower == "soc" {
            return ("SoC \(n)", .cpu)
        }
        if lower.contains("gpu") || lower.contains("tgpu") {
            return ("GPU \(n)", .gpu)
        }
        if lower.contains("ane") {
            return ("Neural Engine \(n)", .other)
        }
        if lower.hasPrefix("isp") {
            return ("ISP (カメラ処理) \(n)", .other)
        }
        if lower.contains("nand") || lower.contains("ssd") || lower.contains("flash") {
            return ("SSD \(n)", .storage)
        }
        if lower.contains("dram") || lower.contains("ddr") || lower.contains("lpddr") {
            return ("メモリ \(n)", .memory)
        }
        if lower.contains("gas gauge") || lower.contains("battery") || lower.hasPrefix("tb") {
            return ("バッテリー \(n)", .battery)
        }
        if lower.contains("tcal") {
            return ("PMU 校正", .other)
        }
        if lower.contains("pmu") || lower.contains("pmic") {
            return ("電源管理 IC\(pmuSuffix(lower))", .power)
        }
        if lower.contains("charger") || lower.contains("tpwr") || lower.contains("usb") || lower.contains("tcc") {
            return ("充電/USB-C", .power)
        }
        if lower.contains("wifi") || lower.contains("wlan") || lower.contains("bluetooth") {
            return ("無線モジュール", .other)
        }
        if lower.contains("ambient") || lower.contains("skin") || lower.contains("palm") || lower.contains("airflow") {
            return ("筐体/周辺", .ambient)
        }

        // ---- Intel の SMC キー ----
        switch raw {
        case "TC0P": return ("CPU 近傍", .cpu)
        case "TC0D", "TC0E", "TC0F", "TC0H": return ("CPU ダイ", .cpu)
        case "TCXC", "TCXc": return ("CPU PECI", .cpu)
        case "TG0P", "TG0D", "TG0H": return ("GPU", .gpu)
        case "TM0P", "TM0S", "Ts0S": return ("メモリ", .memory)
        case "TH0P", "TH0A", "TH0B": return ("SSD", .storage)
        case "TB0T", "TB1T", "TB2T": return ("バッテリー", .battery)
        case "TA0P", "TA1P": return ("周辺気温", .ambient)
        case "Ts0P", "Ts1P": return ("パームレスト", .ambient)
        case "TW0P": return ("無線モジュール", .other)
        case "TPCD": return ("プラットフォーム", .power)
        default: break
        }
        if raw.hasPrefix("Tp") { return ("CPU \(raw)", .cpu) }     // Apple Silicon SMC 側の Tp** 系
        if raw.hasPrefix("Tg") { return ("GPU \(raw)", .gpu) }
        if raw.hasPrefix("TC") { return ("CPU \(raw)", .cpu) }
        if raw.hasPrefix("TG") { return ("GPU \(raw)", .gpu) }
        if raw.hasPrefix("TB") { return ("バッテリー \(raw)", .battery) }
        if raw.hasPrefix("TH") { return ("SSD \(raw)", .storage) }
        if raw.hasPrefix("TM") { return ("メモリ \(raw)", .memory) }
        return (raw, .other)
    }

    /// Intel Mac で SMC から読みにいく代表的な温度キー (存在するものだけ読む)。
    public static let intelTemperatureKeys: [String] = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TCXC",
        "TG0P", "TG0D",
        "TM0P", "TH0P", "TB0T", "TB1T", "TA0P", "Ts0P", "TW0P", "TPCD",
    ]

    /// Apple Silicon で SMC 側からも読める温度キー (IOHID が使えない時のフォールバック)。
    /// caseymrm/go-smc / oshi の知見: Tp01〜Tp16 が CPU ホットスポット, Tg0* が GPU。
    public static let appleSiliconSMCTemperatureKeys: [String] =
        (1...16).map { String(format: "Tp%02d", $0) } + ["Tp0T", "Tp0t", "Tg05", "Tg0D", "Tg0L", "Tg0T", "TH0x", "TB0T", "Ts0P"]
}
