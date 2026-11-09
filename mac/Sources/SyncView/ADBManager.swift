import Foundation
import IOKit

/// Mantém o túnel USB (adb reverse tcp:52020) sempre ativo e abre o app no
/// tablet quando ele é plugado. Também "ressuscita" o servidor do adb quando
/// ele perde o tablet mesmo com o cabo conectado.
final class ADBManager {
    enum State: Equatable {
        case adbMissing
        case noDevice
        case unauthorized
        case ready(serial: String, model: String)
    }

    static let packageName = "com.syncview.receiver"
    // .workItem: drena o autorelease pool a cada execução. Sem isso, os Pipes
    // de cada chamada do adb ficavam acumulados e o app esgotava os 256
    // descritores de arquivo em ~1 h ("Bad file descriptor").
    private let queue = DispatchQueue(label: "syncview.adb", autoreleaseFrequency: .workItem)
    private var timer: DispatchSourceTimer?
    private var knownDevices = Set<String>()
    private(set) var adbPath: String?
    var onStateChange: ((State) -> Void)?
    private var state: State = .noDevice {
        didSet { if state != oldValue { let s = state; DispatchQueue.main.async { self.onStateChange?(s) } } }
    }

    /// Desde quando o tablet está no USB mas o adb não o enxerga.
    private var lostSince: Date?
    private var lastServerRestart = Date.distantPast
    private var failedRestarts = 0
    private var consecutiveTimeouts = 0

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in autoreleasepool { self?.tick() } }
        t.resume()
        timer = t
    }

    /// Reinicia o servidor do adb (útil no menu "Reconectar").
    func restartServer(reason: String) {
        queue.async { [weak self] in autoreleasepool { self?.killServer(reason: reason, force: true) } }
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

        guard let out = run(["devices", "-l"]) else {
            // Servidor do adb travado: depois de 2 timeouts seguidos, reinicia.
            if consecutiveTimeouts >= 2 { killServer(reason: "adb não responde") }
            return
        }
        var ready: [(String, String)] = []
        var unauthorized = false
        var offline = false
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            switch parts[1] {
            case "device":
                let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? serial
                ready.append((serial, model))
            case "unauthorized": unauthorized = true
            case "offline": offline = true
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

        if !ready.isEmpty { failedRestarts = 0 }
        if let first = ready.first { state = .ready(serial: first.0, model: first.1) }
        else if unauthorized { state = .unauthorized }
        else { state = .noDevice }

        // O cabo está ligado (interface ADB presente no USB), mas o servidor
        // do adb não lista o tablet ou o mostra "offline": reinicia o servidor.
        if ready.isEmpty && !unauthorized && Self.adbInterfacePresent() {
            if lostSince == nil { lostSince = Date() }
            if Date().timeIntervalSince(lostSince!) > 6 {
                killServer(reason: offline ? "tablet aparece como offline" : "tablet está no USB mas o adb não o vê")
            }
        } else {
            lostSince = nil
        }
    }

    private func killServer(reason: String, force: Bool = false) {
        // Intervalo crescente (20 s, 40 s, 80 s… até 3 min) para não brigar com o adb
        // quando o problema está no tablet (adbd travado: só replugar resolve).
        let wait = min(20 * pow(2, Double(failedRestarts)), 180)
        guard force || Date().timeIntervalSince(lastServerRestart) > wait else { return }
        lastServerRestart = Date()
        if !force { failedRestarts += 1 }
        lostSince = nil
        consecutiveTimeouts = 0
        Log.info("Reiniciando o servidor do adb (\(reason))")
        _ = run(["kill-server"], timeout: 5)
        // O próximo "adb devices" sobe o servidor de novo.
        knownDevices.removeAll()
    }

    private func ensureReverse(serial: String) {
        let list = run(["-s", serial, "reverse", "--list"]) ?? ""
        if !list.contains("tcp:\(Proto.port)") {
            _ = run(["-s", serial, "reverse", "tcp:\(Proto.port)", "tcp:\(Proto.port)"])
            Log.info("Túnel USB criado (adb reverse tcp:\(Proto.port))")
        }
    }

    private func launchApp(serial: String) {
        // --windowingMode 1 = tela cheia (evita reabrir em janela pop-up do Samsung).
        _ = run(["-s", serial, "shell", "am", "start", "--windowingMode", "1", "-n", "\(Self.packageName)/.MainActivity"])
    }

    /// Há algum aparelho com interface ADB (classe 255, subclasse 66, protocolo 1) no USB?
    static func adbInterfacePresent() -> Bool {
        guard let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return false }
        match["IOPropertyMatch"] = ["bInterfaceClass": 255, "bInterfaceSubClass": 66, "bInterfaceProtocol": 1]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }
        let first = IOIteratorNext(iter)
        guard first != 0 else { return false }
        IOObjectRelease(first)
        return true
    }

    /// Velocidade do link USB do tablet (Mbps). 480 = USB 2.0.
    static func usbLinkSpeedMbps() -> Int? {
        guard let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return nil }
        match["IOPropertyMatch"] = ["bInterfaceClass": 255, "bInterfaceSubClass": 66, "bInterfaceProtocol": 1]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        let iface = IOIteratorNext(iter)
        guard iface != 0 else { return nil }
        defer { IOObjectRelease(iface) }
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(iface, kIOServicePlane, &device) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(device) }
        guard let v = IORegistryEntryCreateCFProperty(device, "UsbLinkSpeed" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return v.intValue / 1_000_000
    }

    /// Executa o adb com timeout (o adb pode travar se o cabo for removido no meio).
    /// Usa posix_spawn direto, com controle total dos descritores: o
    /// Process/Pipe do Foundation vazava um pipe por chamada neste app, e em
    /// ~1 h o limite de 256 arquivos abertos estourava ("Bad file descriptor").
    @discardableResult
    private func run(_ args: [String], timeout: TimeInterval = 6) -> String? {
        guard let adbPath else { return nil }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { Log.error("adb: pipe() falhou: errno \(errno)"); return nil }
        let (rd, wr) = (fds[0], fds[1])
        _ = fcntl(rd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(wr, F_SETFD, FD_CLOEXEC)
        defer { close(rd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, wr, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Só 0, 1 e 2 chegam ao adb (e ao servidor que ele possa iniciar).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = ([adbPath] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, adbPath, &actions, &attr, argv, environ)
        close(wr) // nossa cópia da ponta de escrita; o filho tem a dele
        guard rc == 0 else { Log.error("adb falhou: posix_spawn errno \(rc)"); return nil }

        // Lê até EOF (o adb saiu) ou até o prazo.
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var pfd = pollfd(fd: rd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
            if pr < 0 { if errno == EINTR { continue }; break }
            if pr == 0 { continue }
            let n = read(rd, &buf, buf.count)
            if n > 0 { out.append(buf, count: n) } else if n == 0 { break } else if errno != EINTR { break }
        }

        var status: Int32 = 0
        if timedOut {
            kill(pid, SIGKILL)
            consecutiveTimeouts += 1
            Log.error("adb \(args.joined(separator: " ")) excedeu \(Int(timeout)) s")
            waitpid(pid, &status, 0)
            return nil
        }
        // EOF chegou: o adb fechou a saída; espera ele terminar (rápido).
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        consecutiveTimeouts = 0
        return String(decoding: out, as: UTF8.self)
    }
}
