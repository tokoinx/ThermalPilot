// NotificationService.swift
// 温度が上がった時のローカル通知。UserNotifications は .app バンドルとして起動した時のみ有効
// (`swift run` の素の実行ファイルでは通知センターに登録できないため、静かに無視する)。

import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private var available = false

    private init() {}

    private var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func requestAuthorization() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.available = granted
        }
    }

    func post(title: String, body: String) {
        guard isBundled, available else {
            NSLog("[ThermalPilot] %@ — %@", title, body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "thermal-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
