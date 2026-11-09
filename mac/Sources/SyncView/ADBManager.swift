import Foundation

/// Mantém o túnel USB (adb reverse tcp:52020) sempre ativo e abre o app no
/// tablet quando ele é plugado.
final class ADBManager {
    enum State: Equatable {
        case adbMissing
        case noDevice
        case unauthorized
        case ready(serial: String, model: String)
    }

    static let packageName = "com.syncview.receiver"
    private let queue = DispatchQueue(label: "syncview.adb")
    private var timer: DispatchSourceTimer?
    private var knownDevices = Set<String>()
    private(set) var adbPath: String?
    var onStateChange: ((State) -> Void)?
    private var state: State = .noDevice {
        didSet { if state != oldValue { let s = state; DispatchQueue.main.async { self.onStateChange?(s) } } }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func findADB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func tick() {
        if adbPath == nil { adbPath = findADB() }
        guard adbPath != nil else { state = .adbMissing; return }

        guard let out = run(["devices", "-l"]) else { return }
        var ready: [(String, String)] = []
        var unauthorized = false
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            switch parts[1] {
            case "device":
                let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? serial
                ready.append((serial, model))
            case "unauthorized": unauthorized = true
            default: break
            }
        }

        let current = Set(ready.map { $0.0 })
        for (serial, model) in ready {
            ensureReverse(serial: serial)
            if !knownDevices.contains(serial) {
                Log.info("Tablet USB detectado: \(model) (\(serial))")
                launchApp(serial: serial)
            }
        }
        knownDevices = current

        if let first = ready.first { state = .ready(serial: first.0, model: first.1) }
        else if unauthorized { state = .unauthorized }
        else { state = .noDevice }
    }

    private func ensureReverse(serial: String) {
        let list = run(["-s", serial, "reverse", "--list"]) ?? ""
        if !list.contains("tcp:\(Proto.port)") {
            _ = run(["-s", serial, "reverse", "tcp:\(Proto.port)", "tcp:\(Proto.port)"])
            Log.info("Túnel USB criado (adb reverse tcp:\(Proto.port))")
        }
    }

    private func launchApp(serial: String) {
        _ = run(["-s", serial, "shell", "am", "start", "-n", "\(Self.packageName)/.MainActivity"])
    }

    /// Executa o adb com timeout (o adb pode travar se o cabo for removido no meio).
    @discardableResult
    private func run(_ args: [String], timeout: TimeInterval = 6) -> String? {
        guard let adbPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { Log.error("adb falhou: \(error)"); return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning {
            p.terminate()
            Log.error("adb \(args.joined(separator: " ")) excedeu \(Int(timeout)) s")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
