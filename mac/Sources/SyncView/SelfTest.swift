import AppKit
import CoreMedia
import CoreVideo
import Network

/// `SyncView --selftest`: valida o monitor virtual a 120 Hz, a vazão do
/// encoder em 2960×1848 e, se houver permissão de Gravação de Tela, o
/// pipeline completo com um cliente falso pelo TCP.
enum SelfTest {
    static func print(_ s: String) { Swift.print(s); Log.info("[selftest] " + s) }
    static let w = 2960, h = 1848, fps = 120

    static func start() {
        print("== SyncView selftest ==")
        // 1) Monitor virtual
        guard let vd = VirtualDisplay(name: "SyncView Test", serial: 0xBEEF, pixelWidth: w, pixelHeight: h,
                                      refreshRate: Double(fps), diagonalInches: 14.6, scale: .retina) else {
            print("FALHA: monitor virtual"); exit(1)
        }
        // Mesmo caminho do app: seleção assíncrona logo após criar o monitor.
        vd.select(scale: .retina) { ok in
            print("select assíncrono imediato: \(ok)")
            print("Modos: \(vd.describeModes())")
            let mode = CGDisplayCopyDisplayMode(vd.displayID)!
            print("select(.retina)=\(ok) atual: \(mode.width)×\(mode.height) px \(mode.pixelWidth)×\(mode.pixelHeight) @\(mode.refreshRate)Hz bounds=\(vd.bounds)")
            for s in DisplayScale.allCases {
                let r = vd.selectNow(scale: s)
                let m = CGDisplayCopyDisplayMode(vd.displayID)!
                print("  \(s.rawValue): ok=\(r) → \(m.width)×\(m.height) px \(m.pixelWidth)×\(m.pixelHeight) @\(m.refreshRate)")
            }
            vd.selectNow(scale: .retina)
            DispatchQueue.global().async {
                encoderBenchmark(.hevc)
                encoderBenchmark(.h264)
                DispatchQueue.main.async { pipelineTest(vd) }
            }
        }
        _keep = vd
    }
    static var _keep: Any?

    static func makeBuffers(_ n: Int) -> [CVPixelBuffer] {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        return (0..<n).map { i in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            // Luma: "texto" pseudoaleatório que se desloca a cada quadro (pior caso de rolagem).
            let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb!, 0)
            var seed: UInt32 = 12345
            for row in 0..<h {
                for col in 0..<w {
                    if (col & 7) == 0 { seed = seed &* 1103515245 &+ 12345 }
                    let line = ((row + i * 6) / 24) % 2 == 0
                    y[row * stride + col] = line && (seed >> 16) & 3 == 0 ? 30 : 235
                }
            }
            let uv = CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!.assumingMemoryBound(to: UInt8.self)
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) * h / 2)
            CVPixelBufferUnlockBaseAddress(pb!, [])
            return pb!
        }
    }

    static func encoderBenchmark(_ codec: Codec) {
        let bufs = makeBuffers(8)
        guard let enc = VideoEncoder(width: w, height: h, fps: fps, codec: codec, bitrateMbps: 100) else {
            print("FALHA: encoder \(codec)"); return
        }
        let n = 600
        let done = DispatchSemaphore(value: 0)
        var count = 0, bytes = 0, keys = 0
        var latencies: [Double] = []
        var submit: [Int: Double] = [:]
        let lock = NSLock()
        enc.onOutput = { f in
            lock.lock()
            count += 1; bytes += f.data.count; if f.keyframe { keys += 1 }
            let idx = Int(f.ptsMicros * UInt64(fps) / 1_000_000)
            if let t0 = submit[idx] { latencies.append(CACurrentMediaTime() - t0) }
            let finished = count == n
            lock.unlock()
            if finished { done.signal() }
        }
        let t0 = CACurrentMediaTime()
        for i in 0..<n {
            // Ritmo real de 120 fps.
            let target = t0 + Double(i) / Double(fps)
            let now = CACurrentMediaTime()
            if target > now { Thread.sleep(forTimeInterval: target - now) }
            lock.lock(); submit[i] = CACurrentMediaTime(); lock.unlock()
            enc.encode(bufs[i % bufs.count], pts: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)), forceKeyframe: i == 0)
        }
        _ = done.wait(timeout: .now() + 10)
        let dt = CACurrentMediaTime() - t0
        latencies.sort()
        let p50 = latencies.isEmpty ? 0 : latencies[latencies.count / 2] * 1000
        let p99 = latencies.isEmpty ? 0 : latencies[latencies.count * 99 / 100] * 1000
        print(String(format: "Encoder %@: %d quadros em %.2f s = %.1f fps, %.1f Mbps, latência p50 %.1f ms p99 %.1f ms",
                     codec.label, count, dt, Double(count) / dt, Double(bytes) * 8 / dt / 1e6, p50, p99))
        enc.invalidate()
    }

    /// Cliente TCP falso: manda HELLO e conta quadros recebidos.
    static func pipelineTest(_ vd: VirtualDisplay) {
        guard CGPreflightScreenCaptureAccess() else {
            print("Pulando teste de pipeline: este processo não tem permissão de Gravação de Tela.")
            exit(0)
        }
        _keep = nil // libera o monitor de teste; o Controller cria o seu
        let controller = Controller()
        controller.start()
        _ctl = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Proto.port)!, using: .tcp)
            var hello = Data(Proto.magic)
            hello.appendBE(Proto.version)
            hello.appendBE(UInt32(w)); hello.appendBE(UInt32(h))
            hello.appendBE(Float(120).bitPattern); hello.appendBE(UInt32(274)); hello.append(1)
            hello.appendBE(Float(14.6).bitPattern); hello.append("Fake Tab".data(using: .utf8)!)
            conn.start(queue: .global())
            conn.send(content: Proto.packet(Proto.hello, hello), completion: .idempotent)
            var buf = Data(); var frames = 0; var keys = 0; var bytes = 0; var types = [UInt8: Int]()
            let t0 = CACurrentMediaTime()
            func recv() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, _, err in
                    if let d { buf.append(d) }
                    while buf.count >= 5 {
                        let b = buf.startIndex
                        let len = Int(buf[b+1]) << 24 | Int(buf[b+2]) << 16 | Int(buf[b+3]) << 8 | Int(buf[b+4])
                        guard buf.count >= 5 + len else { break }
                        let t = buf[b]; types[t, default: 0] += 1
                        if t == Proto.frame { frames += 1; bytes += len; if buf[b+5] == 1 { keys += 1 } }
                        buf.removeSubrange(b..<(b + 5 + len))
                    }
                    if err == nil { recv() }
                }
            }
            recv()
            // Gera movimento no monitor virtual: cursor andando em círculo.
            let bounds = CGDisplayBounds(vd.displayID)
            let mover = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { _ in
                let t = CACurrentMediaTime() - t0
                let p = CGPoint(x: bounds.midX + cos(t * 6) * 300, y: bounds.midY + sin(t * 6) * 200)
                CGWarpMouseCursorPosition(p)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                mover.invalidate()
                print("Pipeline: tipos=\(types) quadros=\(frames) keyframes=\(keys) ≈\(frames / 6) fps \(bytes * 8 / 6 / 1_000_000) Mbps")
                print("Taxa do monitor virtual: \(CGDisplayCopyDisplayMode(controller.display?.displayID ?? 0)?.refreshRate ?? 0) Hz")
                exit(0)
            }
        }
    }
    static var _ctl: Controller?
}

extension Data {
    mutating func appendBE(_ v: Float) { appendBE(v.bitPattern) }
}
