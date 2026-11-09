package com.syncview.receiver

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

class MainActivity : Activity(), SurfaceHolder.Callback, StreamClient.Listener {
    companion object { private const val TAG = "SyncView" }

    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private lateinit var statsView: TextView
    private lateinit var touch: TouchHandler
    private val ui = Handler(Looper.getMainLooper())

    private val decoder = VideoDecoder { client.requestKeyframe() }
    private val client: StreamClient by lazy { StreamClient(decoder, ::buildHello, this) }

    private var panelWidth = 0
    private var panelHeight = 0
    private var panelRefresh = 60f
    private var streamFps = 0
    private var streamSize = ""
    private var lastBytes = 0L
    private var showStats = false
    private var statusText = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Desenha também na área da câmera frontal: usa 100% do painel.
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
        window.setDecorFitsSystemWindows(false)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        statusView = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 22f
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(18, 18, 22))
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            setLineSpacing(0f, 1.3f)
        }
        statsView = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 13f
            typeface = Typeface.MONOSPACE
            setBackgroundColor(Color.argb(170, 0, 0, 0))
            setPadding(24, 12, 24, 12)
            visibility = View.GONE
        }
        val root = FrameLayout(this)
        root.setBackgroundColor(Color.BLACK)
        root.addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
        root.addView(statusView, FrameLayout.LayoutParams(-1, -1))
        root.addView(statsView, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START).apply {
            setMargins(32, 0, 0, 32)
        })
        setContentView(root)

        touch = TouchHandler(surfaceView, client::send) { toggleStats() }
        surfaceView.setOnTouchListener { _, e -> touch.onTouch(e) }
        surfaceView.setOnHoverListener { _, e -> touch.onHover(e) }

        decoder.onFirstFrame = { ui.post { statusView.visibility = View.GONE } }

        measurePanel()
        selectHighestRefreshMode()
        setStatus("Aguardando o Mac…")
    }

    /** Resolução física real (paisagem) e taxa máxima do painel. */
    private fun measurePanel() {
        val b = windowManager.maximumWindowMetrics.bounds
        panelWidth = max(b.width(), b.height())
        panelHeight = min(b.width(), b.height())
        val modes = display?.supportedModes ?: emptyArray()
        panelRefresh = modes.maxOfOrNull { it.refreshRate } ?: 60f
        Log.i(TAG, "Painel ${panelWidth}x$panelHeight, modos: ${modes.joinToString { "${it.physicalWidth}x${it.physicalHeight}@${it.refreshRate}" }}")
    }

    /** Pede ao sistema o modo de maior resolução e maior taxa de atualização. */
    private fun selectHighestRefreshMode() {
        val modes = display?.supportedModes ?: return
        val best = modes.maxWithOrNull(compareBy<Display.Mode>({ it.physicalWidth * it.physicalHeight }, { it.refreshRate })) ?: return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = best.modeId
            preferredRefreshRate = best.refreshRate
        }
        Log.i(TAG, "Modo preferido: ${best.physicalWidth}x${best.physicalHeight}@${best.refreshRate}")
    }

    private fun buildHello(): ByteArray {
        val dm = resources.displayMetrics
        val diag = sqrt((panelWidth / dm.xdpi).let { it * it } + (panelHeight / dm.ydpi).let { it * it })
        val name = Settings.Global.getString(contentResolver, "device_name")
            ?: Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?: Build.MODEL
        val hevc = VideoDecoder.supportsHevc(panelWidth, panelHeight, panelRefresh.toDouble())
        return Proto.hello(panelWidth, panelHeight, panelRefresh, dm.densityDpi, hevc, diag, name)
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        client.start()
        ui.post(statsTick)
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(statsTick)
        client.stop()
        setStatus("Pausado")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    // ---- Surface ----

    override fun surfaceCreated(holder: SurfaceHolder) {
        applyFrameRate(holder.surface)
        decoder.setSurface(holder.surface)
        client.requestKeyframe()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        Log.i(TAG, "Surface ${width}x$height")
        applyFrameRate(holder.surface)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        decoder.setSurface(null)
    }

    /** Diz ao compositor que este conteúdo é de 120 fps: mantém o painel a 120 Hz. */
    private fun applyFrameRate(s: Surface) {
        val rate = if (streamFps > 0) streamFps.toFloat() else panelRefresh
        runCatching {
            if (Build.VERSION.SDK_INT >= 31) {
                s.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE, Surface.CHANGE_FRAME_RATE_ALWAYS)
            } else {
                s.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
            }
        }
    }

    // ---- StreamClient.Listener (thread de rede) ----

    override fun onStatus(text: String, connected: Boolean) {
        ui.post {
            if (!connected) setStatus(text)
            else statusText = text
        }
    }

    override fun onStreamStart(codec: Int, width: Int, height: Int, fps: Int) {
        ui.post {
            streamFps = fps
            streamSize = "${width}x$height"
            // Buffer da Surface exatamente do tamanho do vídeo: 1 pixel do Mac = 1 pixel do painel.
            surfaceView.holder.setFixedSize(width, height)
            applyFrameRate(surfaceView.holder.surface)
            if (!decoder.hasRendered) setStatus("Recebendo imagem…")
        }
    }

    private fun setStatus(text: String) {
        statusText = text
        val warn = if (panelRefresh < 100f)
            "\n\n⚠︎ O tablet está limitado a ${panelRefresh.toInt()} Hz.\nAtive Configurações › Tela › Suavidade de movimento › Adaptável."
        else ""
        statusView.text = "SyncView\n\n$text\n\nPainel ${panelWidth}×$panelHeight @ ${panelRefresh.toInt()} Hz$warn"
        if (!decoder.hasRendered) statusView.visibility = View.VISIBLE
    }

    private fun toggleStats() {
        showStats = !showStats
        statsView.visibility = if (showStats) View.VISIBLE else View.GONE
    }

    private val statsTick = object : Runnable {
        override fun run() {
            val frames = decoder.renderedFrames.getAndSet(0)
            val bytes = client.bytesReceived.get()
            val mbps = (bytes - lastBytes) * 8 / 1e6
            lastBytes = bytes
            if (!decoder.hasRendered && statusView.visibility != View.VISIBLE) setStatus(statusText)
            if (showStats) {
                val hz = display?.refreshRate ?: 0f
                statsView.text = "%s %s · alvo %d fps\nexibidos %d fps · tela %.0f Hz\n%.1f Mbps · RTT %.1f ms"
                    .format(client.codecName, streamSize, streamFps, frames, hz, mbps, client.rttMs)
            }
            ui.postDelayed(this, 1000)
        }
    }

    // Caneta pairando chega como evento genérico em alguns aparelhos.
    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean =
        touch.onHover(ev) || super.dispatchGenericMotionEvent(ev)
}
