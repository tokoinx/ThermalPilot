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
        Task {
            // boost は最大 N 分のループなので、バックグラウンドで起動してすぐ戻る
            let ok = await CoolDownActions.runThermalctl(["boost", "--minutes", String(minutes)], detached: true)
            lastError = ok ? nil : "thermalctl boost の起動に失敗しました (認証がキャンセルされた可能性)"
            // 起動直後は PID ファイルがまだ無いことがあるので少し待ってから確認
            try? await Task.sleep(for: .seconds(1.5))
            isFanBoostActive = BackgroundFanController.isAnyControllerRunning
            refreshNow()
        }
    }

    func restoreFansAuto() {
        Task {
            // thermalctl auto は、裏で動いている boost / curve を止めてから自動へ戻す
            let ok = await CoolDownActions.runThermalctl(["auto"])
            lastError = ok ? nil : "thermalctl auto に失敗しました (認証がキャンセルされた可能性)"
            isFanBoostActive = BackgroundFanController.isAnyControllerRunning
            refreshNow()
        }
    }

    func clearError() { lastError = nil }
}
