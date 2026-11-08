// AppSettings.swift
// UserDefaults に保存する設定。Observation で UI と同期する。

import Foundation
import Observation
import ThermalCore

@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let warm = "thresholds.warm"
        static let hot = "thresholds.hot"
        static let critical = "thresholds.critical"
        static let interval = "poll.interval"
        static let notifications = "notifications.enabled"
        static let showTemp = "menubar.showTemperature"
        static let autoLowPower = "actions.autoLowPower"
        static let processLimit = "processes.limit"
    }

    var thresholds: ThermalThresholds {
        didSet {
            defaults.set(thresholds.warm, forKey: Key.warm)
            defaults.set(thresholds.hot, forKey: Key.hot)
            defaults.set(thresholds.critical, forKey: Key.critical)
        }
    }

    /// 更新間隔 (秒)。2〜30。
    var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Key.interval) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    var showTemperatureInMenuBar: Bool {
        didSet { defaults.set(showTemperatureInMenuBar, forKey: Key.showTemp) }
    }

    /// 「危険」レベルに入ったら低電力モードを自動でオンにする (管理者パスワードを求められる)。
    var autoLowPowerOnCritical: Bool {
        didSet { defaults.set(autoLowPowerOnCritical, forKey: Key.autoLowPower) }
    }

    var processLimit: Int {
        didSet { defaults.set(processLimit, forKey: Key.processLimit) }
    }

    init(isAppleSilicon: Bool) {
        let base: ThermalThresholds = isAppleSilicon ? .appleSilicon : .intel
        let d = UserDefaults.standard
        thresholds = ThermalThresholds(
            warm: d.object(forKey: Key.warm) as? Double ?? base.warm,
            hot: d.object(forKey: Key.hot) as? Double ?? base.hot,
            critical: d.object(forKey: Key.critical) as? Double ?? base.critical,
            hysteresis: base.hysteresis
        )
        pollInterval = d.object(forKey: Key.interval) as? Double ?? 3
        notificationsEnabled = d.object(forKey: Key.notifications) as? Bool ?? true
        showTemperatureInMenuBar = d.object(forKey: Key.showTemp) as? Bool ?? true
        autoLowPowerOnCritical = d.object(forKey: Key.autoLowPower) as? Bool ?? false
        processLimit = d.object(forKey: Key.processLimit) as? Int ?? 5
    }

    func resetThresholds(isAppleSilicon: Bool) {
        thresholds = isAppleSilicon ? .appleSilicon : .intel
    }
}
