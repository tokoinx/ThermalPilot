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
        // 同梱版を最優先 (アプリと同じビルドなので挙動が一致する)。無ければ手動インストール先を探す。
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/thermalctl").path,
            "/usr/local/bin/thermalctl",
            "/opt/homebrew/bin/thermalctl",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `sudo thermalctl <args>` 相当を、管理者認証ダイアログ付きで実行し、終わるまで待つ (auto のような短い処理用)。
    static func runThermalctl(_ args: [String]) async -> Bool {
        guard let path = thermalctlPath() else { return false }
        let cmd = ([path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        AppLog.write("thermalctl 実行: \(script)")
        return await runAppleScript(script)
    }

    /// boost のような長い root 処理を、管理者認証付きで「前面」実行する。
    /// - thermalctl は do shell script の前面で動き続け、終わるまで osascript プロセスも残る。
    ///   最初の版はこの方式でファンを全開に保てていた。
    /// - nohup + & のバックグラウンド起動は、実機ログで thermalctl が一度も起動しなかったので使わない。
    /// - アプリ内の NSAppleScript を何分も占有しないよう、osascript を子プロセスとして起動してすぐ戻る。
    /// - 戻り値は osascript のプロセス。起動自体に失敗したら nil。
    static func launchThermalctlInForeground(_ args: [String]) -> Process? {
        guard let path = thermalctlPath() else {
            AppLog.write("thermalctl が見つかりません")
            return nil
        }
        // 標準出力だけ捨てる。標準エラーは残し、失敗した時の理由が osascript のエラーに載るようにする
        let cmd = ([path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            + " >/dev/null"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        AppLog.write("osascript で前面実行: \(script)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.terminationHandler = { finished in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.write("osascript 終了: 終了コード \(finished.terminationStatus)" + (message.isEmpty ? "" : " / \(message)"))
        }
        do {
            try task.run()
        } catch {
            AppLog.write("osascript を起動できません: \(error)")
            return nil
        }
        return task
    }

    // MARK: パスワード無しの停止 (停止ファイル)

    /// 「ファン全開」で起動した boost に渡す停止ファイル。アプリ (一般ユーザー) が作成と削除を行い、
    /// root の boost は 0.1 秒ごとに存在だけを確かめる。root にシグナルを送れないアプリが、
    /// 管理者パスワード無しで boost を止めるための窓口。
    static let boostStopFilePath = NSHomeDirectory() + "/Library/Application Support/ThermalPilot/boost.stop"

    static func requestBoostStop() {
        let directory = (boostStopFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let created = FileManager.default.createFile(atPath: boostStopFilePath, contents: Data())
        AppLog.write("停止ファイルを作成: \(created ? "成功" : "失敗")")
    }

    static func clearBoostStopRequest() {
        try? FileManager.default.removeItem(atPath: boostStopFilePath)
    }

    // MARK: ヘルパー

    private static func runAppleScript(_ source: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let ok = NSAppleScript(source: source)?.executeAndReturnError(&error) != nil
                if let error {
                    // 失敗の理由 (認証キャンセル・構文エラーなど) を握りつぶさず記録する
                    let message = error["NSAppleScriptErrorMessage"] as? String ?? "\(error)"
                    let number = error["NSAppleScriptErrorNumber"] as? Int ?? 0
                    AppLog.write("AppleScript 失敗: \(message) 番号 \(number)")
                } else {
                    AppLog.write("AppleScript 成功")
                }
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
