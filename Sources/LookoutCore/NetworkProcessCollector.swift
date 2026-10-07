import Darwin
import Foundation

enum NetworkProcessCollector {
    private struct Row {
        let pid: Int32
        let name: String
        let time: Double
        let received: UInt64
        let sent: UInt64
    }
    static func parse(_ output: String) -> ProcessListReading {
        var frames: [[Row]] = []
        var columns: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let fields = csv(String(line)) else { return ProcessListReading(message: L10n.text("네트워크 프로세스 응답 형식이 올바르지 않습니다.")) }
            if fields.contains("time"), fields.contains("bytes_in"), fields.contains("bytes_out") {
                columns = fields; frames.append([]); continue
            }
            guard !frames.isEmpty, let input = columns.firstIndex(of: "bytes_in"), let out = columns.firstIndex(of: "bytes_out"),
                  let timestamp = columns.firstIndex(of: "time"), let nameColumn = columns.firstIndex(of: ""),
                  fields.count > [input, out, timestamp, nameColumn].max()!,
                  let time = clockSeconds(fields[timestamp]),
                  let separator = fields[nameColumn].lastIndex(of: "."),
                  let pid = Int32(fields[nameColumn][fields[nameColumn].index(after: separator)...]), pid > 0,
                  let received = UInt64(fields[input]), let sent = UInt64(fields[out]) else {
                return ProcessListReading(message: L10n.text("네트워크 프로세스 응답 형식이 올바르지 않습니다."))
            }
            frames[frames.count - 1].append(Row(pid: pid, name: String(fields[nameColumn][..<separator]),
                time: time, received: received, sent: sent))
        }
        guard frames.count == 2 else { return ProcessListReading(message: L10n.text("네트워크 프로세스 측정을 완료하지 못했습니다.")) }
        let previous = Dictionary(frames[0].map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        let current = Dictionary(frames[1].map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        var invalidTime = false
        let rows = current.values.compactMap { row -> ProcessUsage? in
            guard let old = previous[row.pid], row.name == old.name else { return nil }
            var elapsed = row.time - old.time
            if elapsed < -86_390 { elapsed += 86_400 } // Midnight rollover, not a backward clock adjustment.
            guard elapsed >= 0.5, elapsed <= 3 else { invalidTime = true; return nil }
            // nettop itself supplies interval deltas in frame 2; frame 1 is a lifetime baseline.
            return ProcessUsage(id: EnergyProcessID(pid: row.pid, started: 0), name: row.name,
                primary: Double(row.received) / elapsed, secondary: Double(row.sent) / elapsed)
        }
        return invalidTime ? ProcessListReading(message: L10n.text("네트워크 측정 간격을 확인할 수 없습니다.")) : ProcessListReading(processes: rows)
    }
    private static func clockSeconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3, let hour = Int(parts[0]), (0..<24).contains(hour),
              let minute = Int(parts[1]), (0..<60).contains(minute),
              let second = Double(parts[2]), second.isFinite, (0..<60).contains(second) else { return nil }
        return Double(hour * 3600 + minute * 60) + second
    }
    // nettop's CSV can quote process names containing commas or quotes.
    static func csv(_ line: String) -> [String]? {
        let chars = Array(line); var result: [String] = [], value = "", quoted = false, index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { value.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if char == "," && !quoted { result.append(value); value = "" }
            else { value.append(char) }
            index += 1
        }
        guard !quoted else { return nil }
        result.append(value); return result
    }
    static func collect() async -> ProcessListReading {
        let command = NetworkProcessCommand()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { command.run() }.value
        } onCancel: { command.cancel() }
    }
}

/// A bounded, read-only system command, used only while the network disclosure is open.
/// The lock protects start/cancel; pipe reading runs on a utility task, never the main actor.
private final class NetworkProcessCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func run() -> ProcessListReading {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        child.arguments = ["-P", "-L", "2", "-d", "-n", "-x", "-J", "time,bytes_in,bytes_out", "-s", "1"]
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); return ProcessListReading(message: L10n.text("측정 중단")) }
        process = child
        do { try child.run() } catch {
            process = nil; lock.unlock()
            return ProcessListReading(message: L10n.text("네트워크 프로세스 통계를 시작할 수 없습니다."))
        }
        lock.unlock()
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: timeout)
        defer {
            timeout.cancel(); try? pipe.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        var output = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > 4_000_000 { cancel(); break }
        }
        child.waitUntilExit()
        guard child.terminationStatus == 0 else {
            return ProcessListReading(message: L10n.text("네트워크 프로세스 통계를 읽을 수 없습니다."))
        }
        let parsed = NetworkProcessCollector.parse(String(decoding: output, as: UTF8.self))
        return ProcessListReading(processes: parsed.processes.map { row in
            let name = EnergyCollector.processName(row.id.pid)
            return ProcessUsage(id: row.id, name: name == "PID \(row.id.pid)" ? row.name : name,
                                primary: row.primary, secondary: row.secondary)
        }, message: parsed.message)
    }
}
