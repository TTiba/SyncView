import CoreMedia
import Foundation
import VideoToolbox

enum Codec: String, CaseIterable {
    case hevc, h264
    var label: String { self == .hevc ? "HEVC (H.265) — 120 fps" : "H.264 — até 60 fps" }
    var protoID: UInt8 { self == .hevc ? Proto.codecHEVC : Proto.codecH264 }
}

struct EncodedFrame {
    let data: Data          // Annex B
    let keyframe: Bool
    let ptsMicros: UInt64
    let parameterSets: Data? // Annex B (VPS/SPS/PPS), só em keyframes
}

/// Encoder por hardware (Apple Media Engine), configurado para baixa latência:
/// sem B-frames, modo tempo real, rate control de baixa latência.
final class VideoEncoder {
    let width: Int
    let height: Int
    let fps: Int
    let codec: Codec
    private var session: VTCompressionSession?
    // Dois locks: o VideoToolbox pode chamar o callback de saída de forma
    // síncrona dentro de EncodeFrame, então o callback não pode usar sessionLock.
    private let sessionLock = NSLock()
    private let outputLock = NSLock()
    private var _onOutput: ((EncodedFrame) -> Void)?
    var onOutput: ((EncodedFrame) -> Void)? {
        get { outputLock.lock(); defer { outputLock.unlock() }; return _onOutput }
        set { outputLock.lock(); _onOutput = newValue; outputLock.unlock() }
    }

    init?(width: Int, height: Int, fps: Int, codec: Codec, bitrateMbps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec

        let codecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        // Obs.: kVTVideoEncoderSpecification_EnableLowLatencyRateControl foi
        // medido e limita o HEVC a ~77 fps em 2960×1848 no M4 Pro. Sem ele o
        // encoder sustenta 120 fps com ~15 ms de latência, então não usamos.
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if status != noErr { Log.error("VTCompressionSessionCreate falhou: \(status)") }
        session = s
        guard let session else { return nil }

        func set(_ key: CFString, _ value: Any) {
            let st = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if st != noErr { Log.info("Propriedade \(key) não aplicada (\(st))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        let bps = bitrateMbps * 1_000_000
        set(kVTCompressionPropertyKey_AverageBitRate, bps)
        // Pico de até 2× a média em janelas de 1 s (rolagem/vídeo em tela cheia).
        set(kVTCompressionPropertyKey_DataRateLimits, [bps * 2 / 8, 1] as CFArray)
        // Keyframe periódico só como seguro (TCP não perde pacotes).
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 30)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse!)
        VTCompressionSessionPrepareToEncodeFrames(session)
        Log.info("Encoder \(codec.label) \(width)×\(height)@\(fps) \(bitrateMbps) Mbps")
    }

    /// Thread-safe: pode ser chamado enquanto outra thread invalida o encoder.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let session else { return }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else {
                if status != noErr { Log.error("Erro de encode: \(status)") }
                return
            }
            if let out = self.convert(sample) { self.onOutput?(out) }
        }
        if status != noErr { Log.error("EncodeFrame falhou: \(status)") }
    }

    func invalidate() {
        sessionLock.lock()
        let s = session
        session = nil
        sessionLock.unlock()
        onOutput = nil
        if let s { VTCompressionSessionInvalidate(s) }
    }

    deinit { invalidate() }

    // MARK: - AVCC/HVCC → Annex B

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func convert(_ sample: CMSampleBuffer) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }

        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        let length = CMBlockBufferGetDataLength(block)
        var raw = Data(count: length)
        let st = raw.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard st == noErr else { return nil }

        var nalLen: Int32 = 4
        var paramSets: Data?
        if keyframe {
            var ps = Data()
            var count = 0
            var i = 0
            repeat {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let s: OSStatus
                if codec == .hevc {
                    s = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
                } else {
                    s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen)
                }
                guard s == noErr, let ptr else { break }
                ps.append(contentsOf: Self.startCode)
                ps.append(ptr, count: size)
                i += 1
            } while i < count
            paramSets = ps
        } else {
            // Mesmo sem keyframe precisamos do tamanho do prefixo.
            if codec == .hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLen)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLen)
            }
        }

        var out = Data(capacity: length + 64)
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            var off = 0
            let hl = Int(nalLen)
            while off + hl <= length {
                var n = 0
                for k in 0..<hl { n = (n << 8) | Int(p[off + k]) }
                off += hl
                guard n > 0, off + n <= length else { break }
                out.append(contentsOf: Self.startCode)
                out.append(p.baseAddress! + off, count: n)
                off += n
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        return EncodedFrame(data: out, keyframe: keyframe, ptsMicros: micros, parameterSets: paramSets)
    }
}
