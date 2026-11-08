// CoolDownActions.swift
// 「冷やす」ための具体的な手。
//  - 高負荷プロセスの終了 (SIGTERM / SIGKILL)
//  - 低電力モードの切替 (pmset。管理者権限が要るので osascript 経由で認証ダイアログを出す)
//  - アクティビティモニタを開く
//  - thermalctl (別途インストール) によるファンブースト / 自動復帰

import Foundation
import AppKit

enum CoolDownActions {
    // MARK: プロセス

    enum TerminateError: LocalizedError {
        case failed(errno: Int32)
        var errorDescription: String? {
            switch self {
            case .failed(let e): return String(cString: strerror(e))
            }
        }
    }

    static func terminate(pid: Int32, force: Bool) throws {
        let sig = force ? SIGKILL : SIGTERM
        if kill(pid, sig) != 0 {
            throw TerminateError.failed(errno: errno)
        }
    }

    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    // MARK: 低電力モード

    /// `pmset -g` の lowpowermode 行を読む。root 不要。
    static func isLowPowerModeOn() async -> Bool? {
        let out = await run("/usr/bin/pmset", ["-g"])
        guard let out else { return nil }
        for line in out.split(separator: "\n") where line.contains("lowpowermode") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return nil
    }

    /// 低電力モードを切り替える。pmset の書き込みは root 必須なので管理者認証ダイアログを出す。
    static func setLowPowerMode(_ on: Bool) async -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
        return await runAppleScript(script)
    }

    // MARK: thermalctl 連携

    static func thermalctlPath() -> String? {
        let candidates = [
            "/usr/local/bin/thermalctl",
            "/opt/homebrew/bin/thermalctl",
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/thermalctl").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `sudo thermalctl <args>` 相当を、管理者認証ダイアログ付きで実行する。
    static func runThermalctl(_ args: [String]) async -> Bool {
        guard let path = thermalctlPath() else { return false }
        let cmd = ([path] + args).map { $0.replacingOccurrences(of: "\"", with: "\\\"") }.joined(separator: " ")
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        return await runAppleScript(script)
    }

    // MARK: ヘルパー

    private static func runAppleScript(_ source: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let ok = NSAppleScript(source: source)?.executeAndReturnError(&error) != nil
                cont.resume(returning: ok && error == nil)
            }
        }
    }

    private static func run(_ path: String, _ args: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = args
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                do {
                    try task.run()
                } catch {
                    cont.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                cont.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
