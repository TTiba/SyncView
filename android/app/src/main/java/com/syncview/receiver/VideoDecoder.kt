package com.syncview.receiver

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.util.concurrent.atomic.AtomicInteger

/**
 * Decodificador por hardware (MediaCodec) configurado para latência mínima.
 * Alimentado pela thread de rede; uma thread própria envia os quadros à tela,
 * sempre o mais recente (quadros atrasados são descartados).
 */
class VideoDecoder(private val onNeedKeyframe: () -> Unit) {
    companion object {
        private const val TAG = "SyncView"

        fun mimeFor(codec: Int) =
            if (codec == Proto.CODEC_HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

        /** Existe decoder HEVC por hardware que aguente essa resolução e taxa? */
        fun supportsHevc(width: Int, height: Int, fps: Double): Boolean {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            return list.codecInfos.any { info ->
                !info.isEncoder && info.isHardwareAccelerated &&
                    info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, true) } &&
                    runCatching {
                        info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC).videoCapabilities
                            .areSizeAndRateSupported(width, height, fps)
                    }.getOrDefault(false)
            }
        }
    }

    @Volatile private var surface: Surface? = null
    @Volatile private var surfaceChanged = false

    private var codec: MediaCodec? = null
    private var outputThread: Thread? = null
    private var mime = MediaFormat.MIMETYPE_VIDEO_HEVC
    private var width = 0
    private var height = 0
    private var fps = 120
    private var csd: ByteArray? = null
    private var waitingKeyframe = true

    val renderedFrames = AtomicInteger(0)
    @Volatile var hasRendered = false
        private set
    var onFirstFrame: (() -> Unit)? = null

    /** Chamado pela UI quando a Surface nasce/morre. */
    fun setSurface(s: Surface?) {
        surface = s
        surfaceChanged = true
    }

    // ---- As funções abaixo rodam na thread de rede ----

    fun configureStream(codecId: Int, w: Int, h: Int, rate: Int) {
        mime = mimeFor(codecId)
        width = w; height = h; fps = rate
        csd = null
        release()
    }

    fun onCodecConfig(data: ByteArray) {
        if (csd != null && csd!!.contentEquals(data) && codec != null) return
        csd = data
        release() // novo stream ou parâmetros mudaram: recria no próximo keyframe
    }

    fun onFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean) {
        if (surfaceChanged) {
            surfaceChanged = false
            release()
        }
        if (codec == null) {
            if (!keyframe) { requestKeyframeOnce(); return }
            if (!create()) return
        }
        if (waitingKeyframe && !keyframe) { requestKeyframeOnce(); return }
        waitingKeyframe = false
        if (!queue(data, ptsUs, 0)) {
            Log.w(TAG, "Decoder travado; recriando")
            release()
            onNeedKeyframe()
        }
    }

    private var keyframeRequested = 0L
    private fun requestKeyframeOnce() {
        val now = System.nanoTime()
        if (now - keyframeRequested > 500_000_000L) {
            keyframeRequested = now
            onNeedKeyframe()
        }
    }

    private fun create(): Boolean {
        val s = surface ?: return false
        val config = csd ?: return false
        if (!s.isValid) return false
        val c = try { MediaCodec.createDecoderByType(mime) } catch (e: Exception) {
            Log.e(TAG, "Sem decoder para $mime", e); return false
        }
        val f = MediaFormat.createVideoFormat(mime, width, height)
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
        f.setInteger(MediaFormat.KEY_PRIORITY, 0) // tempo real
        f.setInteger(MediaFormat.KEY_OPERATING_RATE, fps)
        val lowLatency = c.codecInfo.getCapabilitiesForType(mime)
            .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
        if (lowLatency) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        // Chaves do fabricante (Qualcomm/Snapdragon do S9 Ultra); ignoradas se não existirem.
        f.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
        f.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
        try {
            c.configure(f, s, null, 0)
            c.start()
        } catch (e: Exception) {
            Log.e(TAG, "configure falhou (${e.message}); tentando formato simples")
            runCatching { c.reset() }
            try {
                val g = MediaFormat.createVideoFormat(mime, width, height)
                g.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
                c.configure(g, s, null, 0)
                c.start()
            } catch (e2: Exception) {
                Log.e(TAG, "Decoder não iniciou", e2)
                runCatching { c.release() }
                return false
            }
        }
        codec = c
        Log.i(TAG, "Decoder ${c.name} ${width}x$height@$fps lowLatency=$lowLatency")
        if (!queue(config, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)) { release(); return false }
        startOutputThread(c)
        waitingKeyframe = true
        return true
    }

    private fun queue(data: ByteArray, ptsUs: Long, flags: Int): Boolean {
        val c = codec ?: return false
        try {
            // Espera até 500 ms por um buffer de entrada; descartar um P-frame
            // corromperia a imagem, então é melhor esperar ou recomeçar.
            var idx = -1
            val deadline = System.nanoTime() + 500_000_000L
            while (idx < 0 && System.nanoTime() < deadline) {
                idx = c.dequeueInputBuffer(20_000)
            }
            if (idx < 0) return false
            val buf = c.getInputBuffer(idx) ?: return false
            if (data.size > buf.capacity()) {
                Log.e(TAG, "Quadro maior que o buffer (${data.size} > ${buf.capacity()})")
                c.queueInputBuffer(idx, 0, 0, ptsUs, 0)
                return false
            }
            buf.clear()
            buf.put(data)
            c.queueInputBuffer(idx, 0, data.size, ptsUs, flags)
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Erro ao enfileirar", e)
            return false
        }
    }

    private fun startOutputThread(c: MediaCodec) {
        val t = Thread({
            val info = MediaCodec.BufferInfo()
            var pending = -1
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val idx = c.dequeueOutputBuffer(info, if (pending >= 0) 0 else 20_000)
                    if (idx >= 0) {
                        // Chegou um quadro mais novo: descarta o anterior sem exibir.
                        if (pending >= 0) c.releaseOutputBuffer(pending, false)
                        pending = idx
                    } else if (pending >= 0) {
                        c.releaseOutputBuffer(pending, true)
                        pending = -1
                        renderedFrames.incrementAndGet()
                        if (!hasRendered) { hasRendered = true; onFirstFrame?.invoke() }
                    }
                }
            } catch (_: IllegalStateException) {
                // decoder liberado
            } catch (e: Exception) {
                Log.e(TAG, "Thread de saída", e)
            }
        }, "decoder-out")
        t.priority = Thread.MAX_PRIORITY
        t.start()
        outputThread = t
    }

    fun release() {
        val c = codec ?: return
        codec = null
        outputThread?.interrupt()
        runCatching { c.stop() }
        runCatching { c.release() }
        outputThread?.join(300)
        outputThread = null
        waitingKeyframe = true
    }

    fun resetRenderedState() { hasRendered = false }
}
