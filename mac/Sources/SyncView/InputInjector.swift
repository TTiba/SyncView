import AppKit
import ApplicationServices
import CoreGraphics

/// Converte toques/S Pen do tablet em eventos de mouse no macOS.
/// Requer permissão de Acessibilidade.
final class InputInjector {
    /// Retângulo do monitor virtual em pontos globais + pixels do tablet.
    var geometry: () -> (bounds: CGRect, pixelWidth: Int, pixelHeight: Int)? = { nil }
    var invertScroll = false

    private let source = CGEventSource(stateID: .hidSystemState)
    private var leftDown = false
    private var rightDown = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 0
    private var residualX: Float = 0
    private var residualY: Float = 0

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func point(nx: Float, ny: Float) -> CGPoint? {
        guard let g = geometry() else { return nil }
        let x = g.bounds.minX + CGFloat(min(max(nx, 0), 0.9999)) * g.bounds.width
        let y = g.bounds.minY + CGFloat(min(max(ny, 0), 0.9999)) * g.bounds.height
        return CGPoint(x: x, y: y)
    }

    /// action: 0 mover, 1 pressionar, 2 soltar. button: 0 esquerdo, 1 direito.
    func pointer(action: UInt8, button: UInt8, nx: Float, ny: Float) {
        guard let p = point(nx: nx, ny: ny) else { return }
        switch action {
        case 0:
            let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
            post(type, at: p, button: leftDown || !rightDown ? .left : .right, clickState: leftDown || rightDown ? clickCount : 0)
        case 1:
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8
            clickCount = (now - lastClickTime < NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
            lastClickTime = now
            lastClickPoint = p
            if button == 1 {
                rightDown = true
                post(.rightMouseDown, at: p, button: .right, clickState: clickCount)
            } else {
                leftDown = true
                post(.leftMouseDown, at: p, button: .left, clickState: clickCount)
            }
        case 2:
            if button == 1 {
                rightDown = false
                post(.rightMouseUp, at: p, button: .right, clickState: clickCount)
            } else {
                leftDown = false
                post(.leftMouseUp, at: p, button: .left, clickState: clickCount)
            }
        default: break
        }
    }

    /// dx/dy em pixels do tablet (movimento do dedo).
    func scroll(nx: Float, ny: Float, dx: Float, dy: Float) {
        guard let g = geometry(), let p = point(nx: nx, ny: ny) else { return }
        let ptsPerPx = Float(g.bounds.width) / Float(g.pixelWidth)
        let sign: Float = invertScroll ? -1 : 1
        // Acumula frações: rolagem lenta com dois dedos gera deltas < 1 ponto.
        residualX += dx * ptsPerPx * sign
        residualY += dy * ptsPerPx * sign
        let sx = Int32(residualX.rounded(.towardZero))
        let sy = Int32(residualY.rounded(.towardZero))
        guard sx != 0 || sy != 0 else { return }
        residualX -= Float(sx)
        residualY -= Float(sy)
        if !leftDown && !rightDown { post(.mouseMoved, at: p, button: .left, clickState: 0) }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: sy, wheel2: sx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    /// Solta botões presos (ex.: conexão caiu no meio de um arrasto).
    func releaseAll() {
        guard leftDown || rightDown else { return }
        let p = CGEvent(source: nil)?.location ?? .zero
        if leftDown { post(.leftMouseUp, at: p, button: .left, clickState: 1) }
        if rightDown { post(.rightMouseUp, at: p, button: .right, clickState: 1) }
        leftDown = false
        rightDown = false
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clickState: Int) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if clickState > 0 { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        e.post(tap: .cghidEventTap)
    }
}
