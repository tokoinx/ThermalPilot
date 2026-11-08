// AppLog.swift
// アプリ側の診断ログ。~/Library/Logs/ThermalPilot.log に 1 行ずつ追記する。
// ボタンを押した時に何が起きたか (AppleScript の成否とその理由) を後から確認できるようにする。

import Foundation

enum AppLog {
    static let path = NSHomeDirectory() + "/Library/Logs/ThermalPilot.log"

    static func write(_ message: String) {
        NSLog("[ThermalPilot] %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        // ~/Library/Logs は macOS では常にあるが、念のため無ければ作る
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            _ = FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
