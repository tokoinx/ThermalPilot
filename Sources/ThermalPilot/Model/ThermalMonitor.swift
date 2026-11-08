// ThermalMonitor.swift
// 定期的に ThermalEngine からスナップショットを取り、履歴・通知・自動アクションを司る。

import Foundation
import Observation
import ThermalCore

@MainActor
@Observable
final class ThermalMonitor {
    private(set) var snapshot: ThermalSnapshot = .empty
    /// 代表温度の履歴 (直近 10 分ぶん程度)。スパークライン用。
    private(set) var history: [Double] = []
    private(set) var lastError: String?
    private(set) var lowPowerModeOn: Bool?
    private(set) var isThermalctlInstalled = false
    /// thermalctl boost / curve がバックグラウンドで動いているか (PID ファイルで判定)。
    private(set) var isFanBoostActive = false

    let settings: AppSettings
    let isAppleSilicon: Bool

    @ObservationIgnored private let engine: ThermalEngine
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastNotifiedLevel: ThermalLevel = .cool
    @ObservationIgnored private var lastNotificationDate: Date = .distantPast
    @ObservationIgnored private var autoLowPowerTriggered = false
    /// 「ファン全開」で起動した osascript (thermalctl boost を前面で実行中)。
    @ObservationIgnored private var boostProcess: Process?

    private static let historyLimit = 200

    init() {
        let engine = ThermalEngine()
        self.engine = engine
        self.isAppleSilicon = engine.isAppleSilicon
        self.settings = AppSettings(isAppleSilicon: engine.isAppleSilicon)
        engine.updateThresholds(settings.thresholds)
        isThermalctlInstalled = CoolDownActions.thermalctlPath() != nil
        start()
    }

    // MARK: ポーリング

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.settings.pollInterval
                try? await Task.sleep(for: .seconds(max(1, interval)))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// すぐに 1 回更新する。
    func refreshNow() {
        Task { await tick() }
    }

    private func tick() async {
        engine.updateThresholds(settings.thresholds)
        let limit = settings.processLimit
        let engine = self.engine
        // センサー読み取りと ps はバックグラウンドで
        let snap = await Task.detached(priority: .utility) { engine.snapshot(processLimit: limit) }.value
        apply(snap)
        isFanBoostActive = BackgroundFanController.isAnyControllerRunning
        if snapshot.level >= .hot || lowPowerModeOn == nil {
            lowPowerModeOn = await CoolDownActions.isLowPowerModeOn()
        }
    }

    private func apply(_ snap: ThermalSnapshot) {
        if snapshot.timestamp == .distantPast {
            NSLog("[ThermalPilot] 初回スナップショット: %@ / センサー %ld 個 / ファン %ld 個 / 代表温度 %@ / 源 %@",
                  snap.level.label, snap.sensors.count, snap.fans.count,
                  ThermalFormat.celsius(snap.representative), snap.sourceDescription)
        }
        snapshot = snap
        if let rep = snap.representative {
            history.append(rep)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }
        handleLevelChange(snap.level)
    }

    // MARK: 通知と自動アクション

    private func handleLevelChange(_ level: ThermalLevel) {
        defer { lastNotifiedLevel = level }

        // 上がった時だけ、かつ 5 分に 1 回まで
        if level > lastNotifiedLevel, level >= .hot, settings.notificationsEnabled,
           Date().timeIntervalSince(lastNotificationDate) > 300 {
            lastNotificationDate = Date()
            let temp = ThermalFormat.celsius(snapshot.representative)
            let culprit = snapshot.topProcesses.first.map { " 一番の原因候補: \($0.name) (CPU \(Int($0.cpuPercent))%)" } ?? ""
            NotificationService.shared.post(
                title: level == .critical ? "🚨 Mac が危険な温度です (\(temp))" : "🔥 Mac が熱くなっています (\(temp))",
                body: level.mood + culprit
            )
        }

        if level == .critical, settings.autoLowPowerOnCritical, !autoLowPowerTriggered, lowPowerModeOn == false {
            autoLowPowerTriggered = true
            Task {
                let ok = await CoolDownActions.setLowPowerMode(true)
                if ok { lowPowerModeOn = true }
            }
        }
        if level <= .warm { autoLowPowerTriggered = false }
    }

    // MARK: ユーザー操作

    func toggleLowPowerMode() {
        let target = !(lowPowerModeOn ?? false)
        Task {
            let ok = await CoolDownActions.setLowPowerMode(target)
            if ok { lowPowerModeOn = target } else { lastError = "低電力モードの切替に失敗しました (管理者認証がキャンセルされた可能性)" }
        }
    }

    func terminate(_ process: ProcessLoad, force: Bool = false) {
        do {
            try CoolDownActions.terminate(pid: process.pid, force: force)
            lastError = nil
        } catch {
            lastError = "\(process.name) を終了できません: \(error.localizedDescription)"
        }
        refreshNow()
    }

    func boostFans(minutes: Int = 10) {
        let appPID = ProcessInfo.processInfo.processIdentifier
        AppLog.write("「ファン全開」ボタン: アプリ PID \(appPID)")
        // boost は認証後に前面で動き続ける。--parent: このアプリが終了したら boost も自動で終わる
        // 前回の停止ファイルが残っていると起動直後に止まってしまうので、先に消しておく
        CoolDownActions.clearBoostStopRequest()
        guard let process = CoolDownActions.launchThermalctlInForeground(
            ["boost", "--minutes", String(minutes), "--parent", String(appPID),
             "--stop-file", CoolDownActions.boostStopFilePath]
        ) else {
            lastError = "ファン全開を起動できませんでした。理由は ~/Library/Logs/ThermalPilot.log にあります"
            return
        }
        boostProcess = process
        lastError = nil
        Task {
            // パスワード入力を待つので、最大 120 秒まで 0.5 秒ごとに確認する
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                if BackgroundFanController.isAnyControllerRunning {
                    isFanBoostActive = true
                    AppLog.write("ファン制御の起動を確認")
                    refreshNow()
                    return
                }
                if !process.isRunning {
                    isFanBoostActive = false
                    AppLog.write("ファン制御が起動しないまま osascript が終了")
                    lastError = "ファン全開を起動できませんでした。キャンセルまたはエラーです。理由は ~/Library/Logs/ThermalPilot.log にあります"
                    refreshNow()
                    return
                }
            }
            AppLog.write("120 秒待ってもファン制御を確認できませんでした")
        }
    }

    func restoreFansAuto() {
        AppLog.write("「自動に戻す」ボタン")
        let pressedAt = Date()
        Self.recordSpinDown(from: pressedAt)

        // このアプリが起動した boost なら、停止ファイルで止める (パスワード不要、0.1 秒程度で反応)
        if let process = boostProcess, process.isRunning {
            CoolDownActions.requestBoostStop()
            Task {
                for _ in 0..<30 {   // 最大 3 秒待つ
                    try? await Task.sleep(for: .milliseconds(100))
                    if !process.isRunning {
                        CoolDownActions.clearBoostStopRequest()
                        boostProcess = nil
                        isFanBoostActive = false
                        lastError = nil
                        AppLog.write(String(format: "停止ファイルで boost が終了: %.2f 秒", Date().timeIntervalSince(pressedAt)))
                        refreshNow()
                        return
                    }
                }
                // 3 秒で止まらなければ、従来どおり管理者権限で止める
                CoolDownActions.clearBoostStopRequest()
                AppLog.write("3 秒以内に boost が終了しないため、管理者権限で止めます")
                await restoreFansAutoWithAdmin()
            }
            return
        }
        // ターミナルから起動した boost や、手動のまま残ったファンは管理者権限で戻す
        Task { await restoreFansAutoWithAdmin() }
    }

    /// thermalctl auto を管理者権限で実行する (裏で動いている boost / curve を止めてから自動へ戻す)。
    private func restoreFansAutoWithAdmin() async {
        let ok = await CoolDownActions.runThermalctl(["auto"])
        lastError = ok ? nil : "自動に戻せませんでした。理由は ~/Library/Logs/ThermalPilot.log にあります"
        isFanBoostActive = BackgroundFanController.isAnyControllerRunning
        AppLog.write("「自動に戻す」後: ファン制御プロセス \(isFanBoostActive ? "あり" : "なし")")
        if !isFanBoostActive { boostProcess = nil }
        refreshNow()
    }

    /// 「自動に戻す」を押してからファンが止まるまでの回転数を、0.25 秒ごとにアプリのログへ記録する (最大 15 秒)。
    /// 定期更新と競合しないよう、別の SMC 接続で読む。読み取りに root は不要。
    private nonisolated static func recordSpinDown(from start: Date) {
        Task.detached(priority: .utility) {
            guard let smc = try? SMC() else {
                AppLog.write("回転数の記録: SMC に接続できません")
                return
            }
            let fans = FanController(smc: smc)
            while Date().timeIntervalSince(start) < 15 {
                let now = fans.readFans()
                let elapsed = Date().timeIntervalSince(start)
                let summary = now.map { "実\(Int($0.actualRPM)) 目標\(Int($0.targetRPM ?? -1)) \($0.modeLabel)" }
                    .joined(separator: " / ")
                AppLog.write(String(format: "回転数 +%.2f 秒: ", elapsed) + summary)
                if let fastest = now.map(\.actualRPM).max(), fastest < 200 {
                    AppLog.write(String(format: "ファン停止まで %.2f 秒", elapsed))
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            AppLog.write("15 秒以内に止まりきりませんでした")
        }
    }

    func clearError() { lastError = nil }
}
