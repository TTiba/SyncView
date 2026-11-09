import AppKit
import CoreMedia
import Foundation

enum Settings {
    private static let d = UserDefaults.standard
    static var scale: DisplayScale {
        get { DisplayScale(rawValue: d.string(forKey: "scale") ?? "") ?? .retina }
        set { d.set(newValue.rawValue, forKey: "scale") }
    }
    static var bitrateMbps: Int {
        get { let v = d.integer(forKey: "bitrate"); return v == 0 ? 100 : v }
        set { d.set(newValue, forKey: "bitrate") }
    }
    static var codec: Codec {
        get { Codec(rawValue: d.string(forKey: "codec") ?? "") ?? .hevc }
        set { d.set(newValue.rawValue, forKey: "codec") }
    }
    static var invertScroll: Bool {
        get { d.bool(forKey: "invertScroll") }
        set { d.set(newValue, forKey: "invertScroll") }
    }
}

/// Orquestra: túnel USB → conexão → monitor virtual → captura → encoder → envio.
/// Métodos sem sufixo rodam na main thread.
final class Controller {
    let server = StreamServer()
    let adb = ADBManager()
    let capturer = ScreenCapturer()
    let input = InputInjector()
    private let inputQueue = DispatchQueue(label: "syncview.input", qos: .userInteractive)

    private(set) var display: VirtualDisplay?
    private(set) var hello: Hello?
    private(set) var adbState: ADBManager.State = .noDevice
    private(set) var lastError: String?
    private var removeDisplayWork: DispatchWorkItem?
    private var activity: NSObjectProtocol?
    private var sessionID = 0
    private var captureFPS = 120

    // Estado compartilhado com a fila de captura / encoder.
    private let lock = NSLock()
    private var encoder: VideoEncoder?
    private var needKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var streaming = false
    private var framesSent = 0, bytesSent = 0, framesDropped = 0

    // Estatísticas do último segundo (main thread).
    private(set) var statFPS = 0
    private(set) var statMbps = 0.0
    private(set) var statDropped = 0
    var isStreaming: Bool { lock.lock(); defer { lock.unlock() }; return streaming }

    var onUpdate: (() -> Void)?

    /// Máximo de dados na fila do socket antes de pular quadros (~250 ms a 100 Mbps).
    private let maxPendingBytes = 3_000_000
    /// Mantém o monitor virtual vivo após uma desconexão breve (cabo mexeu),
    /// para as janelas não pularem para a tela do MacBook.
    private let displayGraceSeconds: Double = 30
    /// O usuário tocou em "Sair" no tablet: remove o monitor virtual na hora.
    private var userQuit = false
    /// Sessão atual limitada por estar num link USB 2.0.
    private(set) var usb2Limited = false
    static let usb2MaxMbps = 50

    func start() {
        input.invertScroll = Settings.invertScroll
        input.geometry = { [weak self] in
            guard let self, let d = self.displaySnapshot else { return nil }
            return (CGDisplayBounds(d.id), d.w, d.h)
        }
        server.onMessage = { [weak self] type, payload in self?.handleMessage(type, payload) }
        server.onDisconnect = { [weak self] in DispatchQueue.main.async { self?.clientGone() } }
        capturer.onFrame = { [weak self] pb, pts in self?.handleFrame(pb, pts) }
        capturer.onStopped = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.restartCaptureIfNeeded() }
        }
        adb.onStateChange = { [weak self] s in self?.adbState = s; self?.onUpdate?() }
        server.start()
        adb.start()

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickStats() }
    }

    // Snapshot thread-safe da geometria para a injeção de input.
    private var displaySnapshotStorage: (id: CGDirectDisplayID, w: Int, h: Int)?
    private var displaySnapshot: (id: CGDirectDisplayID, w: Int, h: Int)? {
        get { lock.lock(); defer { lock.unlock() }; return displaySnapshotStorage }
        set { lock.lock(); displaySnapshotStorage = newValue; lock.unlock() }
    }

    // MARK: - Mensagens do tablet (fila de rede)

    private func handleMessage(_ type: UInt8, _ payload: Data) {
        var r = Reader(payload)
        switch type {
        case Proto.hello:
            do {
                let h = try Hello.parse(payload)
                DispatchQueue.main.async { self.beginSession(h) }
            } catch {
                Log.error("HELLO inválido: \(error)")
                server.disconnect()
            }
        case Proto.ping:
            server.send(Proto.packet(Proto.pong, payload))
        case Proto.bye:
            Log.info("Tablet: usuário fechou o SyncView")
            DispatchQueue.main.async { self.userQuit = true }
        case Proto.requestKeyframe:
            Log.info("Tablet pediu keyframe")
            requestKeyframe()
        case Proto.pointer:
            guard let action = try? r.u8(), let button = try? r.u8(),
                  let x = try? r.f32(), let y = try? r.f32() else { return }
            inputQueue.async { self.input.pointer(action: action, button: button, nx: x, ny: y) }
        case Proto.scroll:
            guard let x = try? r.f32(), let y = try? r.f32(),
                  let dx = try? r.f32(), let dy = try? r.f32() else { return }
            inputQueue.async { self.input.scroll(nx: x, ny: y, dx: dx, dy: dy) }
        default:
            break
        }
    }

    // MARK: - Sessão (main thread)

    private func beginSession(_ h: Hello) {
        sessionID += 1
        let quiet = hello?.deviceName == h.deviceName && lastError != nil
        hello = h
        lastError = nil
        removeDisplayWork?.cancel()
        removeDisplayWork = nil

        let w = max(h.width, h.height), ht = min(h.width, h.height)
        let fps = Int(min(max(h.refreshRate.rounded(), 30), 120))
        if !quiet { Log.info("HELLO de \(h.deviceName): \(w)×\(ht) @\(h.refreshRate)Hz dpi=\(h.densityDpi) hevc=\(h.supportsHEVC)") }

        if !CGPreflightScreenCaptureAccess() {
            fail("Sem permissão de Gravação de Tela no Mac.\nAjustes do Sistema › Privacidade e Segurança › Gravação de Tela › ative o SyncView e reabra o app.")
            return
        }

        // Reaproveita o monitor virtual se a resolução for a mesma.
        if let d = display, d.pixelWidth != w || d.pixelHeight != ht || Int(d.refreshRate) != fps {
            display = nil
        }
        if display == nil {
            display = VirtualDisplay(name: h.deviceName, serial: 0x0001, pixelWidth: w, pixelHeight: ht,
                                     refreshRate: Double(fps), diagonalInches: h.diagonalInches > 0 ? h.diagonalInches : 14.6,
                                     scale: Settings.scale)
        }
        guard let display else { fail("Não foi possível criar o monitor virtual."); return }
        display.select(scale: Settings.scale) { [weak display] _ in
            Log.info("Taxa do monitor virtual: \(display?.currentRefreshRate ?? 0) Hz")
        }
        displaySnapshot = (display.displayID, w, ht)

        let codec: Codec = h.supportsHEVC ? Settings.codec : .h264
        // H.264 não sustenta 120 fps nessa resolução (medido: ~92 fps), então
        // a captura fica em 60 fps; o monitor virtual continua a 120 Hz.
        let streamFPS = codec == .h264 ? min(fps, 60) : fps
        // USB 2.0 (480 Mbps) não aguenta 100–200 Mbps pelo túnel do adb: o adbd
        // do tablet trava e o tablet fica "offline". Limita a 50 Mbps nesse caso.
        let link = ADBManager.usbLinkSpeedMbps()
        usb2Limited = (link ?? 5000) <= 480 && Settings.bitrateMbps > Self.usb2MaxMbps
        let bitrate = usb2Limited ? Self.usb2MaxMbps : Settings.bitrateMbps
        if usb2Limited { Log.info("Cabo/porta USB 2.0 (\(link ?? 0) Mbps): taxa limitada a \(bitrate) Mbps") }
        guard let enc = VideoEncoder(width: w, height: ht, fps: streamFPS, codec: codec, bitrateMbps: bitrate) else {
            fail("Falha ao criar o encoder de vídeo.")
            return
        }
        enc.onOutput = { [weak self] f in self?.sendFrame(f) }

        var start = Data()
        start.append(codec.protoID)
        start.appendBE(UInt32(w)); start.appendBE(UInt32(ht)); start.appendBE(UInt32(streamFPS))
        server.send(Proto.packet(Proto.streamStart, start))

        lock.lock()
        encoder?.invalidate()
        encoder = enc
        needKeyframe = true
        lastPixelBuffer = nil
        streaming = true
        lock.unlock()

        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Transmitindo para o tablet")
        }
        captureFPS = streamFPS
        startCapture(displayID: display.displayID, w: w, h: ht, fps: streamFPS)
        onUpdate?()
    }

    /// Operações de captura em fila (uma termina antes da próxima começar),
    /// para que um "parar" atrasado nunca derrube uma captura nova.
    private var captureOp: Task<Void, Never>?
    private func enqueueCapture(_ op: @escaping () async -> Void) {
        let prev = captureOp
        captureOp = Task { await prev?.value; await op() }
    }

    private func startCapture(displayID: CGDirectDisplayID, w: Int, h: Int, fps: Int) {
        let sid = sessionID
        enqueueCapture { [weak self] in
            guard let self else { return }
            let current = await MainActor.run { sid == self.sessionID }
            guard current else { return }
            do {
                try await self.capturer.start(displayID: displayID, width: w, height: h, fps: fps)
            } catch {
                await MainActor.run {
                    guard sid == self.sessionID else { return }
                    self.fail("Falha na captura de tela: \(error.localizedDescription)")
                }
            }
        }
    }

    private func restartCaptureIfNeeded() {
        guard isStreaming, let d = display else { return }
        Log.info("Reiniciando captura")
        requestKeyframe()
        startCapture(displayID: d.displayID, w: d.pixelWidth, h: d.pixelHeight, fps: captureFPS)
    }

    private var lastLoggedError: (String, Date)?
    private func fail(_ msg: String) {
        // O tablet tenta de novo a cada segundo: não repete o mesmo erro no log.
        if lastLoggedError?.0 != msg || Date().timeIntervalSince(lastLoggedError!.1) > 60 {
            Log.error(msg)
            lastLoggedError = (msg, Date())
        }
        lastError = msg
        onUpdate?()
        server.sendThenDisconnect(Proto.packet(Proto.status, msg.data(using: .utf8)!))
    }

    private func clientGone() {
        lock.lock()
        let wasStreaming = streaming
        streaming = false
        encoder?.invalidate()
        encoder = nil
        lastPixelBuffer = nil
        lock.unlock()
        inputQueue.async { self.input.releaseAll() }
        sessionID += 1
        enqueueCapture { [weak self] in await self?.capturer.stop() }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }

        let grace = userQuit ? 0.3 : displayGraceSeconds
        userQuit = false
        if wasStreaming, display != nil {
            if grace >= 1 { Log.info("Monitor virtual será removido em \(Int(grace)) s se o tablet não voltar") }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isStreaming else { return }
                Log.info("Removendo monitor virtual")
                self.display = nil
                self.displaySnapshot = nil
                self.onUpdate?()
            }
            removeDisplayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
        }
        onUpdate?()
    }

    /// Reinicia a sessão (o tablet reconecta sozinho em ~1 s) para aplicar codec/bitrate.
    func restartSession() { server.disconnect() }

    func applyScale(_ s: DisplayScale) {
        Settings.scale = s
        display?.select(scale: s) { [weak self] _ in self?.requestKeyframe() }
    }

    func setInvertScroll(_ v: Bool) {
        Settings.invertScroll = v
        inputQueue.async { self.input.invertScroll = v }
    }

    // MARK: - Pipeline de vídeo (fila de captura / threads do VideoToolbox)

    private func handleFrame(_ pb: CVPixelBuffer, _ pts: CMTime) {
        lock.lock()
        guard streaming, let enc = encoder else { lock.unlock(); return }
        lastPixelBuffer = pb
        if !needKeyframe && server.pendingBytes > maxPendingBytes {
            framesDropped += 1
            lock.unlock()
            return
        }
        let force = needKeyframe
        needKeyframe = false
        lock.unlock()
        enc.encode(pb, pts: pts, forceKeyframe: force)
    }

    private func requestKeyframe() {
        lock.lock()
        needKeyframe = true
        let pb = lastPixelBuffer
        let enc = encoder
        let active = streaming
        if active, pb != nil, enc != nil { needKeyframe = false }
        lock.unlock()
        // Tela parada não gera quadros novos: reenvia o último como keyframe.
        if active, let pb, let enc {
            enc.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()), forceKeyframe: true)
        }
    }

    private func sendFrame(_ f: EncodedFrame) {
        guard isStreaming else { return }
        if let ps = f.parameterSets { server.send(Proto.packet(Proto.codecConfig, ps)) }
        var p = Data(capacity: f.data.count + 9)
        p.append(f.keyframe ? 1 : 0)
        p.appendBE(f.ptsMicros)
        p.append(f.data)
        server.send(Proto.packet(Proto.frame, p))
        lock.lock(); framesSent += 1; bytesSent += p.count; lock.unlock()
    }

    private func tickStats() {
        lock.lock()
        statFPS = framesSent
        statMbps = Double(bytesSent) * 8 / 1_000_000
        statDropped = framesDropped
        framesSent = 0; bytesSent = 0; framesDropped = 0
        lock.unlock()
        onUpdate?()
    }
}
