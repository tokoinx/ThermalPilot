// ThermalPilotApp.swift
// メニューバー常駐アプリのエントリポイント。macOS 14+ (MenuBarExtra + Observation)。

import SwiftUI
import AppKit
import ThermalCore

@main
struct ThermalPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor = ThermalMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(monitor)
        } label: {
            MenuBarLabel(snapshot: monitor.snapshot, showTemperature: monitor.settings.showTemperatureInMenuBar)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` で .app バンドル無しに起動した時も Dock に出さない。
        NSApp.setActivationPolicy(.accessory)
        NotificationService.shared.requestAuthorization()
        NSLog("[ThermalPilot] 起動完了。メニューバーに温度計アイコンを挿入します (bundle: %@)", Bundle.main.bundlePath)

        // 2 秒後に status item が実際に存在するか確認してログに出す (ノッチ裏に隠れている時の切り分け用)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let items = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
            NSLog("[ThermalPilot] ステータスバー用ウインドウ数: %ld (0 なら MenuBarExtra が作られていない、1 以上ならノッチ裏に隠れている可能性)", items.count)
        }
    }
}

/// メニューバーに出すアイコン + 温度。
struct MenuBarLabel: View {
    let snapshot: ThermalSnapshot
    let showTemperature: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: snapshot.level.symbolName)
                .symbolRenderingMode(.hierarchical)
            if showTemperature {
                Text(ThermalFormat.celsius(snapshot.representative))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}
