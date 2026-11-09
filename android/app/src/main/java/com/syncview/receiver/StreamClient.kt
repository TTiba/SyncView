package com.syncview.receiver

import android.util.Log
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Conecta em 127.0.0.1:52020 — porta que o `adb reverse` encaminha pelo cabo
 * USB até o Mac. Reconecta sozinho para sempre enquanto estiver ativo.
 */
class StreamClient(
    private val decoder: VideoDecoder,
    private val helloProvider: () -> ByteArray,
    private val listener: Listener,
) {
    interface Listener {
        fun onStatus(text: String, connected: Boolean)
        fun onStreamStart(codec: Int, width: Int, height: Int, fps: Int)
    }

    companion object { private const val TAG = "SyncView" }

    @Volatile private var running = false
    private var thread: Thread? = null
    @Volatile private var socket: Socket? = null
    private val outQueue = LinkedBlockingQueue<ByteArray>(2048)

    val bytesReceived = AtomicLong(0)
    @Volatile var rttMs = 0.0
        private set
    @Volatile var codecName = ""
        private set
    /** Último aviso enviado pelo Mac (ex.: falta permissão); some quando a imagem chega. */
    @Volatile private var macMessage: String? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread({ loop() }, "stream-client").apply { priority = Thread.MAX_PRIORITY; start() }
    }

    fun stop() {
        running = false
        runCatching { socket?.close() }
        thread?.interrupt()
        thread?.join(2000)
        thread = null
        // O decoder é liberado pela própria thread de rede (bloco finally).
    }

    /** Thread-safe; pode ser chamado da UI. Descarta se a fila estiver cheia. */
    fun send(packet: ByteArray) {
        if (socket != null) outQueue.offer(packet)
    }

    private fun loop() {
        var attempt = 0
        while (running) {
            try {
                listener.onStatus(macMessage ?: if (attempt < 2) "Conectando ao Mac…" else "Aguardando o Mac…", false)
                session()
                attempt = 0
            } catch (e: Exception) {
                if (running) Log.i(TAG, "Sessão terminou: ${e.javaClass.simpleName} ${e.message}")
            } finally {
                runCatching { socket?.close() }
                socket = null
                outQueue.clear()
                decoder.release()
                decoder.resetRenderedState()
            }
            attempt++
            if (running) runCatching { Thread.sleep(if (attempt < 5) 300 else 1000) }
        }
    }

    private fun session() {
        val s = Socket()
        s.tcpNoDelay = true
        s.receiveBufferSize = 4 * 1024 * 1024
        s.sendBufferSize = 256 * 1024
        s.connect(InetSocketAddress("127.0.0.1", Proto.PORT), 1500)
        s.soTimeout = 4000 // sem dados por 4 s = conexão morta (o Mac responde aos pings)
        socket = s

        val out = s.getOutputStream()
        out.write(helloProvider())
        out.flush()

        // Thread de escrita: pings a cada 500 ms + eventos de toque.
        val writer = Thread({
            var lastPing = 0L
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val now = System.nanoTime()
                    if (now - lastPing > 500_000_000L) {
                        out.write(Proto.ping()); lastPing = now
                    }
                    val p = outQueue.poll(100, TimeUnit.MILLISECONDS)
                    if (p != null) {
                        out.write(p)
                        // Junta eventos que chegaram ao mesmo tempo antes do flush.
                        while (true) { out.write(outQueue.poll() ?: break) }
                    }
                    out.flush()
                }
            } catch (_: InterruptedException) {
            } catch (e: Exception) {
                runCatching { s.close() }
            }
        }, "stream-writer")
        writer.start()

        try {
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 20))
            var gotStream = false
            while (running) {
                val type = input.readUnsignedByte()
                val len = input.readInt()
                if (len < 0 || len > 32 * 1024 * 1024) throw EOFException("tamanho inválido $len")
                val payload = ByteArray(len)
                input.readFully(payload)
                bytesReceived.addAndGet(len + 5L)
                when (type) {
                    Proto.STREAM_START -> {
                        val b = ByteBuffer.wrap(payload)
                        val codec = b.get().toInt()
                        val w = b.int; val h = b.int; val fps = b.int
                        macMessage = null
                        codecName = if (codec == Proto.CODEC_HEVC) "HEVC" else "H.264"
                        Log.i(TAG, "Stream: $codecName ${w}x$h@$fps")
                        decoder.configureStream(codec, w, h, fps)
                        listener.onStreamStart(codec, w, h, fps)
                        if (!gotStream) { gotStream = true; listener.onStatus("Recebendo imagem…", true) }
                    }
                    Proto.CODEC_CONFIG -> decoder.onCodecConfig(payload)
                    Proto.FRAME -> {
                        val key = payload[0].toInt() == 1
                        val pts = ByteBuffer.wrap(payload, 1, 8).long
                        decoder.onFrame(payload.copyOfRange(9, payload.size), pts, key)
                    }
                    Proto.STATUS -> {
                        val msg = String(payload, Charsets.UTF_8)
                        macMessage = msg
                        listener.onStatus(msg, false)
                    }
                    Proto.PONG -> {
                        if (payload.size >= 8) rttMs = (System.nanoTime() - ByteBuffer.wrap(payload).long) / 1e6
                    }
                }
            }
        } finally {
            writer.interrupt()
            runCatching { s.close() }
            writer.join(500)
        }
    }

    fun requestKeyframe() = send(Proto.packet(Proto.REQUEST_KEYFRAME))
}
