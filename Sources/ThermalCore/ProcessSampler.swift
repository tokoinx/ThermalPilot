// ProcessSampler.swift
// 「何が Mac を熱くしているのか」を特定するため、CPU 使用率上位のプロセスを取る。
// libproc で全プロセスを舐めるより `ps` の出力を読む方が短く、root も不要。

import Foundation

public enum ProcessSampler {
    /// CPU 使用率上位 `limit` 件。失敗時は空配列。
    public static func topProcesses(limit: Int = 5) -> [ProcessLoad] {
        #if os(macOS)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -r: CPU 使用率降順, -c: コマンド名のみ, -e: 全ユーザー, -o: 列指定
        task.arguments = ["-Arcxo", "pid=,pcpu=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(psOutput: text, limit: limit)
        #else
        return []
        #endif
    }

    /// `ps -o pid=,pcpu=,comm=` の出力をパースする (テスト対象)。
    public static func parse(psOutput: String, limit: Int) -> [ProcessLoad] {
        var result: [ProcessLoad] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // pid と pcpu は空白区切り、残り全部がコマンド名 (空白を含みうる)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            let rawName = String(parts[2])
            let name = (rawName as NSString).lastPathComponent
            // 自分自身 (ps) や 0% のものは除外
            guard name != "ps", cpu > 0 else { continue }
            result.append(ProcessLoad(pid: pid, name: name, cpuPercent: cpu))
            if result.count >= limit { break }
        }
        return result
    }
}
