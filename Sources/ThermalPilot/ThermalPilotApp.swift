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
