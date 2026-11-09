package com.syncview.receiver

import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Gestos → mouse do Mac:
 *  • S Pen: aproximar move o cursor, encostar = clique/arrasto,
 *    botão lateral pressionado ao encostar = clique direito.
 *  • 1 dedo: toque = clique (2 toques = duplo clique); tocar e arrastar = arrastar.
 *  • 2 dedos: arrastar = rolagem (com inércia); toque rápido = clique direito.
 *  • 3 dedos: toque = abre o menu do SyncView.
 */
class TouchHandler(
    private val view: View,
    private val send: (ByteArray) -> Unit,
    private val onThreeFingerTap: () -> Unit,
) {
    private enum class State { IDLE, PENDING, DRAG, SCROLL, DONE }

    private val handler = Handler(Looper.getMainLooper())
    private val slop = 8f * view.resources.displayMetrics.density
    private val holdToDragMs = 140L
    private val tapMaxMs = 280L

    private var state = State.IDLE
    private var startX = 0f
    private var startY = 0f
    private var startTime = 0L
    private var lastCx = 0f
    private var lastCy = 0f
    private var scrollMoved = false
    private var scrollStartX = 0f
    private var scrollStartY = 0f
    private var maxPointers = 0
    private var velocity: VelocityTracker? = null
    private var stylusButton = Proto.BUTTON_LEFT

    private fun nx(x: Float) = (x / view.width).coerceIn(0f, 1f)
    private fun ny(y: Float) = (y / view.height).coerceIn(0f, 1f)
    private fun pointer(action: Int, button: Int, x: Float, y: Float) = send(Proto.pointer(action, button, nx(x), ny(y)))

    private val commitDrag = Runnable {
        if (state == State.PENDING) {
            pointer(Proto.ACTION_DOWN, Proto.BUTTON_LEFT, startX, startY)
            state = State.DRAG
        }
    }

    fun onTouch(e: MotionEvent): Boolean {
        val tool = e.getToolType(0)
        if (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER) return onStylus(e)
        stopFling()

        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                state = State.PENDING
                startX = e.x; startY = e.y; startTime = e.eventTime
                maxPointers = 1
                pointer(Proto.ACTION_MOVE, 0, e.x, e.y)
                handler.postDelayed(commitDrag, holdToDragMs)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                maxPointers = maxOf(maxPointers, e.pointerCount)
                if (state == State.PENDING) {
                    handler.removeCallbacks(commitDrag)
                    state = State.SCROLL
                    scrollMoved = false
                    lastCx = centroidX(e); lastCy = centroidY(e)
                    scrollStartX = lastCx; scrollStartY = lastCy
                    velocity?.recycle()
                    velocity = VelocityTracker.obtain()
                }
            }
            MotionEvent.ACTION_MOVE -> when (state) {
                State.PENDING -> if (hypot(e.x - startX, e.y - startY) > slop) {
                    handler.removeCallbacks(commitDrag)
                    pointer(Proto.ACTION_DOWN, Proto.BUTTON_LEFT, startX, startY)
                    state = State.DRAG
                    pointer(Proto.ACTION_MOVE, 0, e.x, e.y)
                }
                State.DRAG -> pointer(Proto.ACTION_MOVE, 0, e.x, e.y)
                State.SCROLL -> if (e.pointerCount >= 2 && maxPointers == 2) {
                    val cx = centroidX(e); val cy = centroidY(e)
                    val dx = cx - lastCx; val dy = cy - lastCy
                    if (!scrollMoved && hypot(cx - scrollStartX, cy - scrollStartY) > slop) scrollMoved = true
                    if (scrollMoved && (dx != 0f || dy != 0f)) send(Proto.scroll(nx(cx), ny(cy), dx, dy))
                    lastCx = cx; lastCy = cy
                    velocity?.addMovement(e)
                }
                else -> {}
            }
            MotionEvent.ACTION_POINTER_UP -> {
                if (state == State.SCROLL) {
                    val quick = e.eventTime - startTime < tapMaxMs
                    if (!scrollMoved && quick && maxPointers == 2) {
                        // Toque com dois dedos = clique direito.
                        pointer(Proto.ACTION_DOWN, Proto.BUTTON_RIGHT, startX, startY)
                        pointer(Proto.ACTION_UP, Proto.BUTTON_RIGHT, startX, startY)
                    } else if (!scrollMoved && quick && maxPointers == 3) {
                        onThreeFingerTap()
                    } else if (scrollMoved) {
                        velocity?.let { v ->
                            v.computeCurrentVelocity(1000)
                            startFling(lastCx, lastCy, v.xVelocity, v.yVelocity)
                        }
                    }
                    state = State.DONE
                }
            }
            MotionEvent.ACTION_UP -> {
                handler.removeCallbacks(commitDrag)
                when (state) {
                    State.PENDING -> {
                        pointer(Proto.ACTION_DOWN, Proto.BUTTON_LEFT, startX, startY)
                        pointer(Proto.ACTION_UP, Proto.BUTTON_LEFT, startX, startY)
                    }
                    State.DRAG -> pointer(Proto.ACTION_UP, Proto.BUTTON_LEFT, e.x, e.y)
                    else -> {}
                }
                state = State.IDLE
                velocity?.recycle(); velocity = null
            }
            MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(commitDrag)
                if (state == State.DRAG) pointer(Proto.ACTION_UP, Proto.BUTTON_LEFT, e.x, e.y)
                state = State.IDLE
            }
        }
        return true
    }

    private fun onStylus(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                stylusButton = if (e.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0)
                    Proto.BUTTON_RIGHT else Proto.BUTTON_LEFT
                pointer(Proto.ACTION_MOVE, 0, e.x, e.y)
                pointer(Proto.ACTION_DOWN, stylusButton, e.x, e.y)
            }
            MotionEvent.ACTION_MOVE -> {
                // Usa os pontos históricos: a S Pen amostra mais rápido que a tela.
                for (i in 0 until e.historySize) pointer(Proto.ACTION_MOVE, 0, e.getHistoricalX(i), e.getHistoricalY(i))
                pointer(Proto.ACTION_MOVE, 0, e.x, e.y)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> pointer(Proto.ACTION_UP, stylusButton, e.x, e.y)
        }
        return true
    }

    /** Caneta pairando sobre a tela move o cursor. */
    fun onHover(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_HOVER_MOVE || e.actionMasked == MotionEvent.ACTION_HOVER_ENTER) {
            pointer(Proto.ACTION_MOVE, 0, e.x, e.y)
            return true
        }
        return false
    }

    private fun centroidX(e: MotionEvent) = (0 until minOf(2, e.pointerCount)).map { e.getX(it) }.average().toFloat()
    private fun centroidY(e: MotionEvent) = (0 until minOf(2, e.pointerCount)).map { e.getY(it) }.average().toFloat()

    // ---- Inércia da rolagem ----
    private var flingVx = 0f
    private var flingVy = 0f
    private var flingX = 0f
    private var flingY = 0f
    private var flingLast = 0L
    private val flingStep = object : Runnable {
        override fun run() {
            val now = System.nanoTime()
            val dt = (now - flingLast) / 1e9f
            flingLast = now
            val decay = Math.pow(0.04, dt.toDouble()).toFloat() // perde 96% da velocidade por segundo
            flingVx *= decay; flingVy *= decay
            if (abs(flingVx) < 40f && abs(flingVy) < 40f) return
            send(Proto.scroll(nx(flingX), ny(flingY), flingVx * dt, flingVy * dt))
            handler.postDelayed(this, 8)
        }
    }

    private fun startFling(x: Float, y: Float, vx: Float, vy: Float) {
        if (hypot(vx, vy) < 600f) return
        flingX = x; flingY = y; flingVx = vx; flingVy = vy
        flingLast = System.nanoTime()
        handler.postDelayed(flingStep, 8)
    }

    private fun stopFling() { handler.removeCallbacks(flingStep) }
}
