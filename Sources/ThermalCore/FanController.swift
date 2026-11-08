// FanController.swift
// SMC 経由のファン読み取り (root 不要) と、オプトインの手動制御 (root 必須)。
//
// Apple Silicon でのファン書き込み手順は agoodkind/macos-smc-fan の研究 (MIT) に基づく:
//   1. F%dMd = 1 (手動) を直接書く。M1 / M5 系はこれで通る。
//   2. 0x82 で拒否され、かつ Ftst キーが存在するなら Ftst = 1 を書く (診断モードのアンロック)。
//   3. 100ms 間隔で F%dMd = 1 を再試行 (最大 10 秒)。thermalmonitord がモード 3 → 0 に落とした隙に通る。
//   4. F%dTg に目標 RPM を書く。
//   復帰: F%dMd = 0、最後の手動ファンを戻す時に Ftst が 1 なら Ftst = 0。
// 注意: スリープ復帰で Ftst はリセットされ、手動制御は失われる (再アンロックが必要)。
// 注意: thermalmonitord がファンを「掴み直す」ので、制御プロセスは生かしておく必要がある。

import Foundation

public struct FanReading: Sendable, Equatable, Identifiable, Codable {
    public var id: Int { index }
    public let index: Int
    public let actualRPM: Double
    public let targetRPM: Double?
    public let minRPM: Double?
    public let maxRPM: Double?
    /// 0 = auto, 1 = manual, 3 = system (thermalmonitord 管理)。読めなければ nil。
    public let mode: Int?

    public init(index: Int, actualRPM: Double, targetRPM: Double?, minRPM: Double?, maxRPM: Double?, mode: Int?) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
    }

    public var modeLabel: String {
        switch mode {
        case 0: return "自動"
        case 1: return "手動"
        case 2: return "強制手動 (T2)"
        case 3: return "システム管理"
        case nil: return "不明"
        default: return "モード \(mode!)"
        }
    }

    /// 最大 RPM に対する割合 (0...1)。max が無ければ nil。
    public var loadFraction: Double? {
        guard let maxRPM, maxRPM > 0 else { return nil }
        return min(1, max(0, actualRPM / maxRPM))
    }
}

public enum FanControlError: Error, CustomStringConvertible {
    case notRoot
    case noFans
    case unlockTimedOut(fan: Int)
    case outOfRange(rpm: Double, min: Double, max: Double)
    case smc(SMCError)

    public var description: String {
        switch self {
        case .notRoot: return "ファン制御には root 権限が必要です (sudo thermalctl ...)"
        case .noFans: return "このMacにはファンがありません (ファンレス機)"
        case .unlockTimedOut(let fan): return "ファン \(fan) の手動モード切替がタイムアウトしました (thermalmonitord に拒否され続けています)"
        case .outOfRange(let rpm, let min, let max): return "\(Int(rpm)) rpm は許容範囲外です (\(Int(min))〜\(Int(max)) rpm)"
        case .smc(let e): return e.description
        }
    }
}

/// `thermalctl boost` / `curve` のようにバックグラウンドでファンを握り続けるプロセスの管理。
/// PID ファイルは root が書き、アプリ (一般ユーザー) は読むだけ。
public enum BackgroundFanController {
    public static let pidFilePath = "/var/run/thermalctl.pid"

    /// 実行中のコントローラの PID。ファイルが無い・プロセスが死んでいれば nil。
    public static func runningPID() -> pid_t? {
        guard let text = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        // kill(pid, 0): 存在すれば 0。root のプロセスに対して一般ユーザーが呼ぶと EPERM だが、それも「存在する」証拠。
        if kill(pid, 0) == 0 || errno == EPERM { return pid }
        return nil
    }

    public static var isRunning: Bool { runningPID() != nil }

    /// 自分を登録する (root で実行される boost / curve 用)。
    public static func register() {
        try? "\(getpid())\n".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    public static func unregister() {
        if runningPID() == getpid() || runningPID() == nil {
            try? FileManager.default.removeItem(atPath: pidFilePath)
        }
    }

    /// PID ファイルを書かない古い版や、ファイルが消えた後も生き残っている boost / curve を
    /// プロセス一覧から探す (`pgrep -f`)。自分自身は除外。
    public static func orphanedControllerPIDs() -> [pid_t] {
        #if os(macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "thermalctl (boost|curve)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let me = getpid()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != me }
        #else
        return []
        #endif
    }

    /// 実行中のコントローラ (PID ファイル登録分 + 迷子のプロセス) に SIGTERM を送り、終了を待つ。
    /// 全部止まったら true。
    @discardableResult
    public static func stop(timeout: TimeInterval = 6) -> Bool {
        var targets = Set<pid_t>(orphanedControllerPIDs())
        if let pid = runningPID() { targets.insert(pid) }
        guard !targets.isEmpty else { return true }

        for pid in targets { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let alive = targets.filter { kill($0, 0) == 0 || errno == EPERM }
            if alive.isEmpty {
                try? FileManager.default.removeItem(atPath: pidFilePath)
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // 粘るものは SIGKILL (root なら通る)
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        Thread.sleep(forTimeInterval: 0.3)
        try? FileManager.default.removeItem(atPath: pidFilePath)
        return targets.allSatisfy { kill($0, 0) != 0 && errno == ESRCH }
    }

    /// アプリ側の「ブースト中」判定: PID ファイル、または迷子プロセスのどちらかがあれば true。
    public static var isAnyControllerRunning: Bool {
        isRunning || !orphanedControllerPIDs().isEmpty
    }
}

#if canImport(IOKit)
public final class FanController {
    private let smc: SMC

    public init(smc: SMC) {
        self.smc = smc
    }

    // MARK: 読み取り

    public func fanCount() -> Int {
        (try? smc.readDouble("FNum")).map { Int($0) } ?? 0
    }

    /// モードキーは機種で大文字/小文字が違う (M4: F0Md, M5: F0md)。存在する方を返す。
    func modeKey(for fan: Int) -> String? {
        let upper = "F\(fan)Md"
        if smc.hasKey(upper) { return upper }
        let lower = "F\(fan)md"
        if smc.hasKey(lower) { return lower }
        return nil
    }

    public func readFans() -> [FanReading] {
        let count = fanCount()
        guard count > 0 else { return [] }
        return (0..<count).compactMap { i in
            guard let actual = try? smc.readDouble("F\(i)Ac") else { return nil }
            let target = try? smc.readDouble("F\(i)Tg")
            let minRPM = try? smc.readDouble("F\(i)Mn")
            let maxRPM = try? smc.readDouble("F\(i)Mx")
            let mode = modeKey(for: i).flatMap { try? smc.readDouble($0) }.map { Int($0) }
            return FanReading(index: i, actualRPM: actual, targetRPM: target, minRPM: minRPM, maxRPM: maxRPM, mode: mode)
        }
    }

    // MARK: 書き込み (root)

    private func requireRoot() throws {
        guard geteuid() == 0 else { throw FanControlError.notRoot }
    }

    /// 手動モードへ切り替える。必要なら Ftst アンロックを行う。
    public func enterManualMode(fan: Int, timeout: TimeInterval = 10) throws {
        try requireRoot()
        guard let key = modeKey(for: fan) else { throw FanControlError.smc(.keyNotFound("F\(fan)Md")) }

        // 1. 直接書き込み
        do {
            try smc.writeDouble(key, 1)
            if (try? smc.readDouble(key)) == 1 { return }
        } catch SMCError.writeBlocked {
            // 2. へ
        }

        // 2. Ftst アンロック (無い機種はそのまま再試行)
        if smc.hasKey("Ftst") {
            try smc.writeDouble("Ftst", 1)
        }

        // 3. 再試行ループ
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? smc.writeDouble(key, 1)) != nil, (try? smc.readDouble(key)) == 1 {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw FanControlError.unlockTimedOut(fan: fan)
    }

    /// 目標 RPM を設定する。範囲はハードウェアが報告する Min/Max で clamp (FanBar と同じ安全策)。
    public func setTarget(fan: Int, rpm: Double) throws {
        try requireRoot()
        let fans = readFans()
        guard let info = fans.first(where: { $0.index == fan }) else { throw FanControlError.noFans }
        let lo = info.minRPM ?? 0
        let hi = info.maxRPM ?? 8000
        guard rpm >= lo, rpm <= hi else { throw FanControlError.outOfRange(rpm: rpm, min: lo, max: hi) }

        if info.mode != 1 {
            try enterManualMode(fan: fan)
        }
        do {
            try smc.writeDouble("F\(fan)Tg", rpm)
        } catch let e as SMCError {
            throw FanControlError.smc(e)
        }
    }

    /// 自動制御へ戻す。
    public func restoreAuto(fan: Int) throws {
        try requireRoot()
        if let key = modeKey(for: fan) {
            do { try smc.writeDouble(key, 0) } catch let e as SMCError { throw FanControlError.smc(e) }
        }
        // 他に手動のファンが残っていなければ Ftst を戻す
        let stillManual = readFans().contains { $0.index != fan && $0.mode == 1 }
        if !stillManual, smc.hasKey("Ftst"), (try? smc.readDouble("Ftst")) == 1 {
            try? smc.writeDouble("Ftst", 0)
        }
    }

    public func restoreAutoAll() {
        for f in readFans() { try? restoreAuto(fan: f.index) }
    }
}
#endif
