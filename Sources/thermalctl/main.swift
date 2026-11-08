// thermalctl — ターミナル用 CLI。
//
//   thermalctl sensors [--json]        温度センサー一覧 (root 不要)
//   thermalctl fans [--json]           ファン RPM / モード (root 不要)
//   thermalctl status [--json]         まとめて表示 (アプリのメニューと同じ内容)
//   thermalctl watch [--interval N]    N 秒ごとに status をライブ表示
//   thermalctl keys [PREFIX]           SMC キーを列挙 (診断用)
//   sudo thermalctl set FAN RPM        ファンを手動で RPM に固定
//   sudo thermalctl boost              全ファンを最大 RPM に (10 分で自動復帰)
//   sudo thermalctl auto [FAN]         自動制御へ戻す
//   sudo thermalctl curve [--profile balanced]  温度に追従してファンを回し続ける (Ctrl-C で復帰)
//
// 外部依存なし (swift-argument-parser を使わず手でパース) — オフラインでもビルドできるように。

import Foundation
import ThermalCore

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"
let wantsJSON = args.contains("--json")

func flagValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let engine = ThermalEngine()
/// Ctrl-C / SIGTERM を受けたら 1 になる (シグナルハンドラから触るのでグローバル)。
var restoreRequested: Int32 = 0

func bar(_ fraction: Double, width: Int = 20) -> String {
    let filled = Int((min(1, max(0, fraction)) * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func printStatus(_ snap: ThermalSnapshot) {
    let t = engine.thresholds
    print("ThermalPilot  \(snap.isAppleSilicon ? "Apple Silicon" : "Intel")  源: \(snap.sourceDescription)")
    print("代表温度: \(ThermalFormat.celsius(snap.representative, fractionDigits: 1))  レベル: \(snap.level.label)  \(snap.level.mood)")
    print("OS サーマルプレッシャー: \(snap.pressure.label)")
    print("")
    for (category, readings) in snap.groupedSensors {
        print("[\(category.rawValue)]")
        for r in readings {
            let frac = (r.celsius - 20) / (t.critical + 10 - 20)
            print(String(format: "  %-22@ %@ %6.1f°", r.label as NSString, bar(frac), r.celsius))
        }
    }
    if !snap.fans.isEmpty {
        print("[ファン]" + (BackgroundFanController.runningPID().map { "  ※ thermalctl boost/curve 実行中 (PID \($0))" } ?? ""))
        for f in snap.fans {
            let range = (f.minRPM.map { Int($0) } ?? 0, f.maxRPM.map { Int($0) } ?? 0)
            print("  ファン\(f.index + 1)  \(bar(f.loadFraction ?? 0))  \(ThermalFormat.rpm(f.actualRPM))  目標 \(ThermalFormat.rpm(f.targetRPM))  範囲 \(range.0)〜\(range.1)  \(f.modeLabel)")
        }
    } else {
        print("[ファン] なし (ファンレス機、または SMC 未検出)")
    }
    if !snap.topProcesses.isEmpty {
        print("[CPU 上位プロセス]")
        for p in snap.topProcesses {
            print(String(format: "  %6d  %5.1f%%  %@", p.pid, p.cpuPercent, p.name as NSString))
        }
    }
    let tips = ThermalPolicy.advice(for: snap.level, topProcess: snap.topProcesses.first)
    print("[提案]")
    tips.forEach { print("  • \($0)") }
}

#if canImport(IOKit)
func requireFans() -> FanController {
    guard let fc = engine.fans else { fail("AppleSMC に接続できません") }
    guard fc.fanCount() > 0 else { fail(FanControlError.noFans.description) }
    return fc
}

/// Ctrl-C / SIGTERM (= `thermalctl auto` からの停止要求) で自動へ戻す。PID ファイルも登録する。
func installRestoreOnExit(_ fc: FanController) {
    // 先に動いている boost / curve があれば止める (二重起動で綱引きにならないように)
    if BackgroundFanController.isRunning || !BackgroundFanController.orphanedControllerPIDs().isEmpty {
        print("既に動いているファン制御を停止します…")
        BackgroundFanController.stop()
    }
    BackgroundFanController.register()
    // シグナルハンドラ内では最小限の処理のみ: restore フラグを立て、8 秒の番犬 (SIGALRM) を仕掛ける。
    // ループが何らかの理由で抜けられなくても、SIGALRM の既定動作で確実にプロセスが終了する
    // (ファンは手動のまま残るが、`thermalctl auto` がその後で戻す)。
    signal(SIGINT) { _ in restoreRequested = 1; alarm(8) }
    signal(SIGTERM) { _ in restoreRequested = 1; alarm(8) }
}

/// restoreRequested を見ながら細かく眠る (停止要求に 0.2 秒以内で反応するため)。
func sleepUnlessStopped(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while restoreRequested == 0, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
    }
}

/// ループを抜けた後の後始末。
func finishBackgroundControl(_ fc: FanController) {
    fc.restoreAutoAll()
    BackgroundFanController.unregister()
    print("自動制御に戻しました。")
}
#endif

switch command {
case "sensors":
    let (readings, source) = engine.readSensors()
    if wantsJSON { printJSON(readings) } else {
        print("源: \(source)")
        for r in readings.sorted(by: { $0.category.sortOrder < $1.category.sortOrder }) {
            print(String(format: "%-10@ %-22@ %6.1f°  (%@)", r.category.rawValue as NSString, r.label as NSString, r.celsius, r.rawName as NSString))
        }
    }

case "fans":
    let fans = engine.readFans()
    if wantsJSON { printJSON(fans) } else if fans.isEmpty {
        print("ファンなし")
    } else {
        for f in fans {
            print("ファン\(f.index + 1): \(ThermalFormat.rpm(f.actualRPM))  目標 \(ThermalFormat.rpm(f.targetRPM))  min \(ThermalFormat.rpm(f.minRPM))  max \(ThermalFormat.rpm(f.maxRPM))  \(f.modeLabel)")
        }
    }

case "status":
    let snap = engine.snapshot()
    if wantsJSON { printJSON(snap) } else { printStatus(snap) }

case "watch":
    let interval = Double(flagValue("--interval") ?? "2") ?? 2
    while true {
        let snap = engine.snapshot()
        print("\u{1B}[2J\u{1B}[H", terminator: "")  // 画面クリア
        printStatus(snap)
        print("\n(\(Int(interval)) 秒ごとに更新 · Ctrl-C で終了)")
        Thread.sleep(forTimeInterval: interval)
    }

case "keys":
    #if canImport(IOKit)
    guard let smc = engine.smcConnection else { fail("AppleSMC に接続できません") }
    let prefix = args.dropFirst().first { !$0.hasPrefix("--") } ?? ""
    do {
        let keys = try smc.allKeys().filter { prefix.isEmpty || $0.hasPrefix(prefix) }
        for k in keys {
            if let info = try? smc.keyInfo(k) {
                let v = (try? smc.readDouble(k)).map { String(format: "%.3f", $0) } ?? "-"
                print("\(k)  \(info.typeString)  size=\(info.dataSize)  \(v)")
            }
        }
        print("\(keys.count) keys")
    } catch { fail("\(error)") }
    #else
    fail("macOS 専用")
    #endif

case "set":
    #if canImport(IOKit)
    guard args.count >= 3, let fan = Int(args[1]), let rpm = Double(args[2]) else { fail("使い方: sudo thermalctl set FAN RPM") }
    let fc = requireFans()
    do {
        try fc.setTarget(fan: fan, rpm: rpm)
        print("ファン\(fan + 1) を \(Int(rpm)) rpm に設定しました (手動モード)。戻すには: sudo thermalctl auto \(fan)")
        print("注意: thermalmonitord が数秒で制御を取り戻す機種があります。継続制御には `curve` を使ってください。")
    } catch { fail("\(error)") }
    #else
    fail("macOS 専用")
    #endif

case "boost":
    #if canImport(IOKit)
    let fc = requireFans()
    let minutes = Double(flagValue("--minutes") ?? "10") ?? 10
    let fans = fc.readFans()
    do {
        for f in fans { try fc.setTarget(fan: f.index, rpm: f.maxRPM ?? 6000) }
        print("全ファン最大。\(Int(minutes)) 分後に自動へ戻します (Ctrl-C でも戻ります)。")
        installRestoreOnExit(fc)
        let deadline = Date().addingTimeInterval(minutes * 60)
        while Date() < deadline, restoreRequested == 0 {
            // thermalmonitord に奪い返されても再設定し続ける
            for f in fc.readFans() where f.mode != 1 && restoreRequested == 0 {
                try? fc.setTarget(fan: f.index, rpm: f.maxRPM ?? 6000)
            }
            sleepUnlessStopped(2)
        }
        finishBackgroundControl(fc)
    } catch { finishBackgroundControl(fc); fail("\(error)") }
    #else
    fail("macOS 専用")
    #endif

case "auto":
    #if canImport(IOKit)
    let fc = requireFans()
    // 裏で boost / curve が動いていたら、まずそれを止める (止めないと 2 秒後に再設定されて「戻らない」)。
    // PID ファイルを書かない古い版のループも pgrep で探して止める。
    let running = Set(BackgroundFanController.orphanedControllerPIDs() + (BackgroundFanController.runningPID().map { [$0] } ?? []))
    if !running.isEmpty {
        print("実行中のファン制御 (PID \(running.sorted().map(String.init).joined(separator: ", "))) を停止します…")
        if !BackgroundFanController.stop() { print("警告: 停止を確認できませんでした。sudo pkill -f 'thermalctl boost' を試してください。") }
    }
    if args.count >= 2, let fan = Int(args[1]) {
        do { try fc.restoreAuto(fan: fan); print("ファン\(fan + 1) を自動に戻しました") } catch { fail("\(error)") }
    } else {
        fc.restoreAutoAll()
        print("全ファンを自動に戻しました")
    }
    #else
    fail("macOS 専用")
    #endif

case "curve":
    #if canImport(IOKit)
    let fc = requireFans()
    let curve = FanCurve.balanced
    print("ファンカーブ制御を開始 (balanced)。Ctrl-C で自動へ戻します。")
    installRestoreOnExit(fc)
    while restoreRequested == 0 {
        let snap = engine.snapshot(processLimit: 0)
        if let temp = snap.representative {
            for f in fc.readFans() {
                let target = min(f.maxRPM ?? 6000, max(f.minRPM ?? 0, curve.rpm(at: temp)))
                if target <= (f.minRPM ?? 0), f.mode == 1 {
                    try? fc.restoreAuto(fan: f.index)   // 十分冷えたら OS に任せる (0 rpm まで落とせるのは OS だけ)
                } else if target > (f.minRPM ?? 0) {
                    try? fc.setTarget(fan: f.index, rpm: target)
                }
            }
            print(String(format: "%@  %5.1f°  → %@", ISO8601DateFormatter().string(from: Date()) as NSString, temp,
                         fc.readFans().map { "\(Int($0.actualRPM))rpm" }.joined(separator: " / ") as NSString))
        }
        sleepUnlessStopped(3)
    }
    finishBackgroundControl(fc)
    #else
    fail("macOS 専用")
    #endif

case "-h", "--help", "help":
    print("""
    thermalctl — Mac の温度・ファンを見る/制御する

      thermalctl sensors [--json]
      thermalctl fans [--json]
      thermalctl status [--json]
      thermalctl watch [--interval N]
      thermalctl keys [PREFIX]
      sudo thermalctl set FAN RPM
      sudo thermalctl boost [--minutes N]
      sudo thermalctl auto [FAN]
      sudo thermalctl curve
    """)

default:
    fail("不明なコマンド: \(command)  (thermalctl --help)")
}
