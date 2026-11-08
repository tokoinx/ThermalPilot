// MenuView.swift
// メニューバーのアイコンをクリックした時に出るパネル。

import SwiftUI
import AppKit
import ThermalCore

@MainActor
struct MenuView: View {
    @Environment(ThermalMonitor.self) private var monitor
    @Environment(\.openSettings) private var openSettings
    @State private var expandedCategories: Set<SensorCategory> = [.cpu, .gpu]
    @State private var confirmKill: ProcessLoad?

    private var snap: ThermalSnapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            sensorSection
            if !snap.fans.isEmpty {
                Divider()
                fanSection
            }
            Divider()
            processSection
            Divider()
            actionSection
            if let err = monitor.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .onTapGesture { monitor.clearError() }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .confirmationDialog(
            "\(confirmKill?.name ?? "") を終了しますか？",
            isPresented: Binding(get: { confirmKill != nil }, set: { if !$0 { confirmKill = nil } }),
            presenting: confirmKill
        ) { p in
            Button("終了 (保存を促す)") { monitor.terminate(p) }
            Button("強制終了", role: .destructive) { monitor.terminate(p, force: true) }
            Button("キャンセル", role: .cancel) {}
        } message: { p in
            Text("PID \(p.pid) · CPU \(Int(p.cpuPercent))%。未保存の作業があると失われます。")
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: snap.level.symbolName)
                        .foregroundStyle(levelColor)
                    Text(ThermalFormat.celsius(snap.representative))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(snap.level.label)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(levelColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(levelColor)
                }
                Text(snap.level.mood)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text("OS サーマル: \(snap.pressure.label)")
                }
                .font(.caption2)
                .foregroundStyle(snap.pressure.rawValue >= 2 ? .orange : .secondary)
            }
            Spacer()
            Sparkline(values: monitor.history, color: levelColor)
                .frame(width: 90, height: 36)
        }
    }

    private var levelColor: Color {
        switch snap.level {
        case .cool: return .blue
        case .warm: return .green
        case .hot: return .orange
        case .critical: return .red
        }
    }

    // MARK: センサー

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if snap.sensors.isEmpty {
                Label(snap.sourceDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snap.groupedSensors, id: \.0) { category, readings in
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedCategories.contains(category) },
                        set: { if $0 { expandedCategories.insert(category) } else { expandedCategories.remove(category) } }
                    )
                ) {
                    ForEach(readings) { r in
                        HStack {
                            Text(r.label).font(.caption)
                            Spacer()
                            TemperatureBar(celsius: r.celsius, thresholds: monitor.settings.thresholds)
                                .frame(width: 70, height: 5)
                            Text(ThermalFormat.celsius(r.celsius, fractionDigits: 1))
                                .font(.caption.monospacedDigit())
                                .frame(width: 46, alignment: .trailing)
                        }
                        .padding(.leading, 4)
                    }
                } label: {
                    HStack {
                        Text(category.rawValue).font(.callout.weight(.medium))
                        Spacer()
                        Text("最高 \(ThermalFormat.celsius(readings.map(\.celsius).max()))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: ファン

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(snap.fans) { fan in
                HStack {
                    Image(systemName: "fan.fill")
                        .symbolEffect(.pulse, options: .repeating, isActive: fan.actualRPM > 50)
                    Text("ファン \(fan.index + 1)").font(.callout)
                    Text(fan.modeLabel).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let frac = fan.loadFraction {
                        ProgressView(value: frac).frame(width: 70)
                    }
                    Text(ThermalFormat.rpm(fan.actualRPM))
                        .font(.callout.monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
    }

    // MARK: プロセス

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("熱の犯人候補 (CPU 上位)").font(.callout.weight(.medium))
                Spacer()
                Button { CoolDownActions.openActivityMonitor() } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                }
                .buttonStyle(.borderless)
                .help("アクティビティモニタを開く")
            }
            if snap.topProcesses.isEmpty {
                Text("取得できませんでした").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snap.topProcesses) { p in
                HStack {
                    Text(p.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(Int(p.cpuPercent))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(p.cpuPercent > 80 ? .orange : .secondary)
                    Button { confirmKill = p } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("\(p.name) を終了")
                }
            }
        }
    }

    // MARK: アクション

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("冷却アクション").font(.callout.weight(.medium))
            HStack {
                Button {
                    monitor.toggleLowPowerMode()
                } label: {
                    Label(
                        monitor.lowPowerModeOn == true ? "低電力モード: ON" : "低電力モード: OFF",
                        systemImage: monitor.lowPowerModeOn == true ? "leaf.fill" : "leaf"
                    )
                }
                .help("pmset で低電力モードを切り替えます (管理者認証)")
                Spacer()
            }
            if monitor.isThermalctlInstalled, !snap.fans.isEmpty {
                HStack {
                    Button { monitor.boostFans() } label: { Label("ファン全開", systemImage: "wind") }
                        .help("thermalctl boost (管理者認証)")
                    Button { monitor.restoreFansAuto() } label: { Label("自動に戻す", systemImage: "arrow.uturn.backward") }
                    Spacer()
                }
            } else if !snap.fans.isEmpty {
                Text("ファン制御は thermalctl のインストール後に使えます (README 参照)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(ThermalPolicy.advice(for: snap.level, topProcess: snap.topProcesses.first), id: \.self) { tip in
                Label(tip, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: フッター

    private var footer: some View {
        HStack {
            Text("\(snap.isAppleSilicon ? "Apple Silicon" : "Intel") · \(snap.sourceDescription)")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("設定…") { openSettings() }
                .buttonStyle(.borderless)
            Button("終了") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
    }
}

/// しきい値に応じて色が変わる小さな温度バー。
struct TemperatureBar: View {
    let celsius: Double
    let thresholds: ThermalThresholds

    var body: some View {
        GeometryReader { geo in
            let frac = min(1, max(0, (celsius - 20) / (thresholds.critical + 10 - 20)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color).frame(width: geo.size.width * frac)
            }
        }
    }

    private var color: Color {
        switch ThermalPolicy.rawLevel(for: celsius, thresholds: thresholds) {
        case .cool: return .blue
        case .warm: return .green
        case .hot: return .orange
        case .critical: return .red
        }
    }
}

/// 代表温度の推移を描く簡易スパークライン。
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let range = max(hi - lo, 5)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / range))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Text("履歴を収集中…").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
