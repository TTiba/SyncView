package com.syncview.receiver

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
import android.window.OnBackInvokedDispatcher
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

class MainActivity : Activity(), SurfaceHolder.Callback, StreamClient.Listener {
    companion object { private const val TAG = "SyncView" }

    private lateinit var surfaceView: SurfaceView
    private lateinit var statusView: TextView
    private lateinit var statusPanel: FrameLayout
    private lateinit var menuView: FrameLayout
    private lateinit var menuInfo: TextView
    private lateinit var statsButton: TextView
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
            typeface = Typeface.create("sans-serif-light", Typeface.NORMAL)
            setLineSpacing(0f, 1.3f)
        }
        // Tela de espera: texto + botões sempre visíveis para sair.
        statusPanel = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(18, 18, 22))
            isClickable = true
            addView(statusView, FrameLayout.LayoutParams(-1, -1))
            val bar = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(pill("Reconectar", accent = false) { reconnect() })
                addView(spacer(dp(16)))
                addView(pill("Sair do SyncView", accent = true) { quit() })
            }
            addView(bar, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                bottomMargin = dp(48)
            })
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
        root.addView(statusPanel, FrameLayout.LayoutParams(-1, -1))
        root.addView(statsView, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START).apply {
            setMargins(32, 0, 0, 32)
        })
        menuView = buildMenu()
        root.addView(menuView, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)

        // Gesto "voltar" (deslizar da borda) abre/fecha o menu em vez de sair direto.
        if (Build.VERSION.SDK_INT >= 33) {
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { toggleMenu() }
        }

        touch = TouchHandler(surfaceView, client::send) { toggleMenu() }
        surfaceView.setOnTouchListener { _, e -> touch.onTouch(e) }
        surfaceView.setOnHoverListener { _, e -> touch.onHover(e) }

        decoder.onFirstFrame = { ui.post { statusPanel.visibility = View.GONE } }

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
        warnIfWindowed()
        client.start()
        ui.post(statsTick)
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        warnIfWindowed()
    }

    /** Em janela pop-up/tela dividida o Samsung reduz a imagem: avisa como voltar. */
    private fun warnIfWindowed() {
        if (isInMultiWindowMode) {
            Toast.makeText(this, "SyncView está em janela. Toque em ⛶ (tela cheia) na barra da janela.", Toast.LENGTH_LONG).show()
        }
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
        if (!decoder.hasRendered) statusPanel.visibility = View.VISIBLE
    }

    private fun toggleStats() {
        showStats = !showStats
        statsView.visibility = if (showStats) View.VISIBLE else View.GONE
        statsButton.text = if (showStats) "Ocultar estatísticas" else "Mostrar estatísticas"
    }

    // ---- Menu (toque com 3 dedos ou gesto de voltar) ----

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun spacer(size: Int) = View(this).apply { layoutParams = LinearLayout.LayoutParams(size, size) }

    private fun pill(text: String, accent: Boolean, onClick: () -> Unit) = TextView(this).apply {
        this.text = text
        textSize = 17f
        gravity = Gravity.CENTER
        setTextColor(Color.WHITE)
        setPadding(dp(28), dp(14), dp(28), dp(14))
        minWidth = dp(220)
        background = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(if (accent) Color.rgb(196, 52, 60) else Color.argb(40, 255, 255, 255))
        }
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

    private fun buildMenu(): FrameLayout {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(32), dp(28), dp(32), dp(28))
            background = GradientDrawable().apply {
                cornerRadius = dp(24).toFloat()
                setColor(Color.rgb(30, 30, 36))
            }
            isClickable = true // toques no cartão não fecham o menu
        }
        card.addView(TextView(this).apply {
            text = "SyncView"
            textSize = 24f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        })
        menuInfo = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.argb(170, 255, 255, 255))
            gravity = Gravity.CENTER
            setPadding(0, dp(6), 0, dp(20))
        }
        card.addView(menuInfo)
        fun add(v: View) {
            card.addView(v, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        }
        add(pill("Voltar para a tela", accent = false) { hideMenu() })
        statsButton = pill("Mostrar estatísticas", accent = false) { toggleStats(); hideMenu() }
        add(statsButton)
        add(pill("Reconectar", accent = false) { hideMenu(); reconnect() })
        add(pill("Sair do SyncView", accent = true) { quit() })
        card.addView(TextView(this).apply {
            text = "Abra este menu com um toque de 3 dedos\nou com o gesto de voltar."
            textSize = 12f
            setTextColor(Color.argb(120, 255, 255, 255))
            gravity = Gravity.CENTER
            setPadding(0, dp(18), 0, 0)
        })

        return FrameLayout(this).apply {
            setBackgroundColor(Color.argb(150, 0, 0, 0))
            visibility = View.GONE
            isClickable = true
            setOnClickListener { hideMenu() } // tocar fora do cartão fecha
            addView(card, FrameLayout.LayoutParams(dp(380), -2, Gravity.CENTER))
        }
    }

    private fun toggleMenu() = if (menuView.visibility == View.VISIBLE) hideMenu() else showMenu()

    private fun showMenu() {
        menuInfo.text = if (decoder.hasRendered)
            "Conectado · ${client.codecName} $streamSize @ $streamFps fps"
        else statusText
        menuView.visibility = View.VISIBLE
    }

    private fun hideMenu() {
        menuView.visibility = View.GONE
        hideSystemBars()
    }

    private fun reconnect() {
        client.stop() // a thread de rede libera o decoder ao sair
        setStatus("Reconectando…")
        client.start()
    }

    /** Avisa o Mac (que remove o monitor virtual na hora) e fecha o app. */
    private fun quit() {
        client.send(Proto.bye())
        menuView.visibility = View.GONE
        ui.postDelayed({ finishAndRemoveTask() }, 250)
    }

    @Deprecated("Usado só quando o callback de voltar preditivo não está ativo")
    override fun onBackPressed() = toggleMenu()

    private val statsTick = object : Runnable {
        override fun run() {
            val frames = decoder.renderedFrames.getAndSet(0)
            val bytes = client.bytesReceived.get()
            val mbps = (bytes - lastBytes) * 8 / 1e6
            lastBytes = bytes
            if (!decoder.hasRendered && statusPanel.visibility != View.VISIBLE) setStatus(statusText)
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
