package com.syncview.receiver

import java.nio.ByteBuffer

/** Protocolo SyncView v1 — espelho de mac/Sources/SyncView/Protocol.swift. */
object Proto {
    const val PORT = 52020
    const val VERSION = 1
    val MAGIC = "SYNV".toByteArray()

    // Tablet → Mac
    const val HELLO: Int = 0x01
    const val REQUEST_KEYFRAME: Int = 0x02
    const val PING: Int = 0x03
    const val BYE: Int = 0x04 // usuário fechou o app: o Mac remove o monitor na hora
    const val POINTER: Int = 0x10
    const val SCROLL: Int = 0x11

    // Mac → Tablet
    const val STREAM_START: Int = 0x81
    const val CODEC_CONFIG: Int = 0x82
    const val FRAME: Int = 0x83
    const val PONG: Int = 0x84
    const val STATUS: Int = 0x85

    const val CODEC_H264 = 0
    const val CODEC_HEVC = 1

    const val ACTION_MOVE = 0
    const val ACTION_DOWN = 1
    const val ACTION_UP = 2
    const val BUTTON_LEFT = 0
    const val BUTTON_RIGHT = 1

    fun packet(type: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        val b = ByteBuffer.allocate(5 + payload.size)
        b.put(type.toByte()).putInt(payload.size).put(payload)
        return b.array()
    }

    fun hello(width: Int, height: Int, refresh: Float, dpi: Int, hevc: Boolean, diagonal: Float, name: String): ByteArray {
        val n = name.toByteArray()
        val b = ByteBuffer.allocate(4 + 2 + 4 + 4 + 4 + 4 + 1 + 4 + n.size)
        b.put(MAGIC).putShort(VERSION.toShort()).putInt(width).putInt(height)
            .putFloat(refresh).putInt(dpi).put(if (hevc) 1 else 0).putFloat(diagonal).put(n)
        return packet(HELLO, b.array())
    }

    fun pointer(action: Int, button: Int, nx: Float, ny: Float): ByteArray {
        val b = ByteBuffer.allocate(10)
        b.put(action.toByte()).put(button.toByte()).putFloat(nx).putFloat(ny)
        return packet(POINTER, b.array())
    }

    fun scroll(nx: Float, ny: Float, dx: Float, dy: Float): ByteArray {
        val b = ByteBuffer.allocate(16)
        b.putFloat(nx).putFloat(ny).putFloat(dx).putFloat(dy)
        return packet(SCROLL, b.array())
    }

    fun bye(): ByteArray = packet(BYE)

    fun ping(): ByteArray = packet(PING, ByteBuffer.allocate(8).putLong(System.nanoTime()).array())
}
