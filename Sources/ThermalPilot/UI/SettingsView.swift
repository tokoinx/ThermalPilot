// SettingsView.swift
// しきい値・更新間隔・通知の設定画面。

import SwiftUI
import ThermalCore

struct SettingsView: View {
    @Environment(ThermalMonitor.self) private var monitor

    var body: some View {
        @Bindable var settings = monitor.settings
        Form {
            Section("温度のしきい値 (℃)") {
                thresholdSlider("ほんのり", value: $settings.thresholds.warm, range: 40...90)
                thresholdSlider("アツい", value: $settings.thresholds.hot, range: 50...105)
                thresholdSlider("危険", value: $settings.thresholds.critical, range: 60...115)
                HStack {
                    Text("この機種の既定: \(monitor.isAppleSilicon ? "Apple Silicon (65 / 85 / 100)" : "Intel (60 / 80 / 95)")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("既定に戻す") { settings.resetThresholds(isAppleSilicon: monitor.isAppleSilicon) }
                }
            }
            Section("監視") {
                HStack {
                    Text("更新間隔")
                    Slider(value: $settings.pollInterval, in: 2...30, step: 1)
                    Text("\(Int(settings.pollInterval)) 秒").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Stepper("表示するプロセス数: \(settings.processLimit)", value: $settings.processLimit, in: 3...10)
                Toggle("メニューバーに温度を表示", isOn: $settings.showTemperatureInMenuBar)
            }
            Section("通知と自動アクション") {
                Toggle("「アツい」以上になったら通知する", isOn: $settings.notificationsEnabled)
                Toggle("「危険」で低電力モードを自動でオンにする (管理者認証が出ます)", isOn: $settings.autoLowPowerOnCritical)
            }
            Section("情報") {
                LabeledContent("センサー源", value: monitor.snapshot.sourceDescription)
                LabeledContent("thermalctl", value: monitor.isThermalctlInstalled ? "インストール済み" : "未インストール")
                Text("ファン制御は Apple Silicon では thermalmonitord に阻まれるため、別途 `sudo thermalctl` が必要です。詳細は README を参照。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: settings.pollInterval) { _, _ in monitor.start() }
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))°").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
