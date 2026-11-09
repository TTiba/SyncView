import Foundation
import Network

/// Servidor TCP em 127.0.0.1:52020. O tablet chega aqui pelo túnel USB do
/// `adb reverse`, então nada é exposto na rede.
final class StreamServer {
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "syncview.net", qos: .userInteractive)
    private var buffer = Data()
    private var lastReceive = Date()
    private var watchdog: DispatchSourceTimer?

    private let lock = NSLock()
    private var _pendingBytes = 0
    /// Bytes enviados ao socket e ainda não confirmados (backpressure).
    var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return _pendingBytes }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    private var _connected = false

    var onMessage: ((UInt8, Data) -> Void)?
    var onDisconnect: (() -> Void)?

    func start() {
        queue.async { self.startListener() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.checkHealth() }
        t.resume()
        watchdog = t
    }

    private func startListener() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Proto.port)!)
        do {
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: Log.info("Servidor ouvindo em 127.0.0.1:\(Proto.port)")
                case .failed(let e):
                    Log.error("Listener falhou: \(e). Reiniciando em 2 s")
                    self?.listener?.cancel()
                    self?.listener = nil
                    self?.queue.asyncAfter(deadline: .now() + 2) { self?.startListener() }
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.error("Não foi possível abrir a porta \(Proto.port): \(error). Tentando de novo em 2 s")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.startListener() }
        }
    }

    private func accept(_ c: NWConnection) {
        if connection != nil {
            Log.info("Nova conexão substitui a anterior")
            closeCurrent(notify: true)
        }
        connection = c
        buffer.removeAll(keepingCapacity: true)
        lastReceive = Date()
        lock.lock(); _pendingBytes = 0; _connected = true; lock.unlock()
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.connection else { return }
            switch state {
            case .ready: break
            case .failed(let e): Log.error("Conexão falhou: \(e)"); self.closeCurrent(notify: true)
            case .cancelled: break
            default: break
            }
        }
        c.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, c === self.connection else { return }
            if let data, !data.isEmpty {
                self.lastReceive = Date()
                self.buffer.append(data)
                self.parse()
            }
            if complete || error != nil {
                Log.info("Tablet desconectou\(error.map { ": \($0)" } ?? "")")
                self.closeCurrent(notify: true)
                return
            }
            self.receive(on: c)
        }
    }

    private func parse() {
        while buffer.count >= 5 {
            let b = buffer.startIndex
            let type = buffer[b]
            let len = Int(buffer[b + 1]) << 24 | Int(buffer[b + 2]) << 16 | Int(buffer[b + 3]) << 8 | Int(buffer[b + 4])
            guard len < 1_000_000 else {
                Log.error("Pacote inválido (\(len) bytes); derrubando conexão")
                closeCurrent(notify: true)
                return
            }
            guard buffer.count >= 5 + len else { return }
            let payload = buffer.subdata(in: (b + 5)..<(b + 5 + len))
            buffer.removeSubrange(b..<(b + 5 + len))
            onMessage?(type, payload)
        }
    }

    /// Thread-safe. Envia mantendo a ordem de chamada.
    func send(_ packet: Data) {
        lock.lock(); _pendingBytes += packet.count; lock.unlock()
        queue.async { [weak self] in
            guard let self, let c = self.connection else {
                self?.lock.lock(); self?._pendingBytes = 0; self?.lock.unlock()
                return
            }
            c.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.lock(); self._pendingBytes = max(0, self._pendingBytes - packet.count); self.lock.unlock()
                if let error {
                    if case .posix(let code) = error, code == .ECANCELED { return } // fechamento normal
                    Log.error("Erro de envio: \(error)")
                    self.queue.async { if c === self.connection { self.closeCurrent(notify: true) } }
                }
            })
        }
    }

    func disconnect() { queue.async { self.closeCurrent(notify: true) } }

    /// Envia um último pacote e só então fecha (para o aviso chegar ao tablet).
    func sendThenDisconnect(_ packet: Data) {
        queue.async { [weak self] in
            guard let self, let c = self.connection else { return }
            c.send(content: packet, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + 0.2) {
                    if c === self.connection { self.closeCurrent(notify: true) }
                }
            })
        }
    }

    private func closeCurrent(notify: Bool) {
        guard let c = connection else { return }
        connection = nil
        c.stateUpdateHandler = nil
        c.cancel()
        lock.lock(); _pendingBytes = 0; _connected = false; lock.unlock()
        if notify { onDisconnect?() }
    }

    /// O tablet manda ping a cada 500 ms. 4 s de silêncio = conexão morta.
    private func checkHealth() {
        if connection != nil, Date().timeIntervalSince(lastReceive) > 4 {
            Log.error("Sem resposta do tablet há 4 s; reiniciando conexão")
            closeCurrent(notify: true)
        }
    }
}
