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

var args = Array(CommandLine.arguments.dropFirst())
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

// --daemonize: 二重 fork で完全に独立したプロセスになる。
// osascript の「管理者権限」トランポリンは, 配下でバックグラウンド起動したプロセスを
// 終了時に道連れに殺す。setsid + 二重 fork で新しいセッションの長となり launchd に
// 里親付けされることで, アプリ側から起動しても boost/curve が生き残れるようにする。
// ThermalEngine (IOKit 接続) はこの後で生成するので, fork はまだシングルスレッドの状態で行われる。
if args.contains("--daemonize") {
    args.removeAll { $0 == "--daemonize" }
    let pid1 = fork()
    if pid1 < 0 { fail("fork に失敗しました") }
    if pid1 > 0 { exit(0) }            // 元の親 (トランポリン配下) は即終了 → 認証ダイアログが閉じる
    setsid()                            // 新しいセッションの長になり制御端末から切り離す
    let pid2 = fork()
    if pid2 < 0 { _exit(1) }
    if pid2 > 0 { _exit(0) }            // 中間の子も終了 → 孫だけが残り launchd 配下へ
    // 孫プロセスが以降を担当。親の標準入出力は閉じられるため /dev/null へ付け替える。
    freopen("/dev/null", "r", stdin)
    freopen("/dev/null", "w", stdout)
    freopen("/dev/null", "w", stderr)
}

let engine = ThermalEngine()
/// Ctrl-C / SIGTERM を受けたら 1 になる (シグナルハンドラから触るのでグローバル)。
var restoreRequested: Int32 = 0
/// `--parent PID`: この PID (ThermalPilot.app) が消えたら boost / curve を終了して自動に戻す。
/// アプリを終了したのにファンが全開のまま、という事故を防ぐ。
let parentPID: pid_t? = flagValue("--parent").flatMap { pid_t($0) }

func parentIsGone() -> Bool {
    guard let parentPID else { return false }
    return kill(parentPID, 0) != 0 && errno == ESRCH
}

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

/// restoreRequested と親アプリの生存を見ながら細かく眠る (停止要求に 0.2 秒以内で反応するため)。
func sleepUnlessStopped(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while restoreRequested == 0, Date() < deadline {
        if parentIsGone() {
            print("ThermalPilot.app が終了したので自動制御に戻します。")
            restoreRequested = 1
            return
        }
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
        // 書き込みが効いたか読み返す (SMC は書き込み成功を返しても thermalmonitord が即座に上書きすることがある)
        Thread.sleep(forTimeInterval: 0.5)
        if let after = fc.readFans().first(where: { $0.index == fan }) {
            print("ファン\(fan + 1): 設定後 目標 \(ThermalFormat.rpm(after.targetRPM)) / 実 \(ThermalFormat.rpm(after.actualRPM)) / \(after.modeLabel)")
            if (after.targetRPM ?? 0) < rpm * 0.9 {
                print("⚠️ 目標 RPM が反映されていません。この機種/OS では F\(fan)Tg への書き込みが thermalmonitord に拒否されている可能性があります。")
            }
        }
        print("戻すには: sudo thermalctl auto \(fan)")
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
        Thread.sleep(forTimeInterval: 0.5)
        for f in fc.readFans() {
            print("  ファン\(f.index + 1): 目標 \(ThermalFormat.rpm(f.targetRPM)) / 実 \(ThermalFormat.rpm(f.actualRPM)) / \(f.modeLabel)")
        }
        installRestoreOnExit(fc)
        let deadline = Date().addingTimeInterval(minutes * 60)
        while Date() < deadline, restoreRequested == 0 {
            // thermalmonitord に奪い返されても再設定し続ける
            let now = fc.readFans()
            for f in now where f.mode != 1 && restoreRequested == 0 {
                try? fc.setTarget(fan: f.index, rpm: f.maxRPM ?? 6000)
            }
            print("  " + now.map { "ファン\($0.index + 1) \(Int($0.actualRPM))rpm(\($0.modeLabel))" }.joined(separator: " / "))
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
      sudo thermalctl boost [--minutes N] [--parent PID]   (--parent: その PID が消えたら自動へ戻して終了)
      sudo thermalctl auto [FAN]
      sudo thermalctl curve [--parent PID]
    """)

default:
    fail("不明なコマンド: \(command)  (thermalctl --help)")
}
