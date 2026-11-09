// Gera os ícones do SyncView (Mac .icns + Android adaptativo) com CoreGraphics.
// Uso: swift tools/make-icons.swift   (a partir da raiz do projeto)
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func save(_ ctx: CGContext, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Fundo: gradiente diagonal índigo → ciano.
func drawBackground(_ ctx: CGContext, rect: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [rgb(0x3B2FD9), rgb(0x2563EB), rgb(0x06B6D4)] as CFArray,
                       locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Brilho suave no topo.
    let shine = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY),
                           startRadius: 0, endCenter: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.maxY),
                           endRadius: rect.width * 0.9, options: [])
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Símbolo: monitor do Mac atrás + tablet na frente, ligados por um "pulso" de sincronia.
/// `box` é a área útil (quadrada) onde o símbolo deve caber.
func drawGlyph(_ ctx: CGContext, box: CGRect) {
    let u = box.width / 100 // unidade

    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * u, y: box.minY + y * u) }
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: box.minX + x * u, y: box.minY + y * u, width: w * u, height: h * u)
    }

    // Sombra comum.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2.2 * u), blur: 6 * u, color: rgb(0x0B1040, 0.45))

    // Monitor (atrás, em cima à esquerda).
    let mon = R(4, 36, 62, 44)
    ctx.addPath(roundedRect(mon, 5 * u)); ctx.setFillColor(rgb(0xFFFFFF, 0.95)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(mon.insetBy(dx: 3.2 * u, dy: 3.2 * u), 2.6 * u))
    ctx.setFillColor(rgb(0x1E2A78)); ctx.fillPath()
    // Pé do monitor.
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    ctx.addPath(roundedRect(R(29, 28, 12, 9), 1.5 * u)); ctx.fillPath()
    ctx.addPath(roundedRect(R(22, 25, 26, 4.2), 2.1 * u)); ctx.fillPath()

    // Conteúdo da tela do monitor: janelas estilizadas.
    ctx.setFillColor(rgb(0x6D8BFF, 0.9))
    ctx.addPath(roundedRect(R(11, 60, 22, 13), 1.6 * u)); ctx.fillPath()
    ctx.setFillColor(rgb(0x38D5F0, 0.85))
    ctx.addPath(roundedRect(R(36, 52, 22, 21), 1.6 * u)); ctx.fillPath()

    // Tablet (frente, embaixo à direita), em paisagem.
    let tab = R(40, 14, 56, 37)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2.5 * u), blur: 7 * u, color: rgb(0x0B1040, 0.55))
    ctx.addPath(roundedRect(tab, 6 * u)); ctx.setFillColor(rgb(0x111827)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(tab, 6 * u)); ctx.setStrokeColor(rgb(0xFFFFFF, 0.95)); ctx.setLineWidth(1.6 * u); ctx.strokePath()
    // Tela do tablet: continuação das "janelas" (mesma imagem do Mac).
    let screen = tab.insetBy(dx: 3.4 * u, dy: 3.4 * u)
    let sg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                        colors: [rgb(0x2B3A9A), rgb(0x1E2A78)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, 3.4 * u)); ctx.clip()
    ctx.drawLinearGradient(sg, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    ctx.setFillColor(rgb(0x38D5F0, 0.9))
    ctx.addPath(roundedRect(R(48, 21, 24, 23), 1.6 * u)); ctx.fillPath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.85))
    ctx.addPath(roundedRect(R(75, 33, 15, 11), 1.4 * u)); ctx.fillPath()
    ctx.setFillColor(rgb(0x6D8BFF, 0.9))
    ctx.addPath(roundedRect(R(75, 21, 15, 9), 1.4 * u)); ctx.fillPath()
    ctx.restoreGState()
    // Câmera frontal do S9 Ultra.
    ctx.setFillColor(rgb(0x4B5563))
    ctx.fillEllipse(in: CGRect(x: tab.midX - 0.9 * u, y: tab.maxY - 2.6 * u, width: 1.8 * u, height: 1.8 * u))

    // Seta de sincronia (cabo) do monitor para o tablet.
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(3.2 * u); ctx.setLineCap(.round)
    let path = CGMutablePath()
    path.move(to: P(14, 22))
    path.addCurve(to: P(34, 9), control1: P(14, 13), control2: P(24, 9))
    ctx.addPath(path); ctx.strokePath()
    // Ponta da seta.
    ctx.setLineJoin(.round)
    ctx.move(to: P(29, 14)); ctx.addLine(to: P(35, 9)); ctx.addLine(to: P(29, 4))
    ctx.strokePath()
}

// ---------- macOS (.icns) ----------
func macIcon(_ size: Int) -> CGContext {
    let ctx = makeContext(size)
    let s = CGFloat(size)
    // Grade da Apple: forma de 824/1024 centralizada, raio ~22,5%.
    let inset = s * 100 / 1024
    let shape = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(roundedRect(shape, shape.width * 0.225)); ctx.setFillColor(rgb(0x2563EB)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(shape, shape.width * 0.225)); ctx.clip()
    drawBackground(ctx, rect: shape)
    drawGlyph(ctx, box: shape.insetBy(dx: shape.width * 0.11, dy: shape.width * 0.11))
    ctx.restoreGState()
    return ctx
}

let iconset = root.appendingPathComponent("mac/Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
for base in [16, 32, 128, 256, 512] {
    save(macIcon(base), iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    save(macIcon(base * 2), iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
save(macIcon(1024), root.appendingPathComponent("tools/preview-mac.png"))

// ---------- Android (ícone adaptativo) ----------
// 108dp de tela, área segura de 66dp no centro. xxxhdpi = 432 px.
let res = root.appendingPathComponent("android/app/src/main/res")
let densities: [(String, Int)] = [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]
for (d, px) in densities {
    let s = CGFloat(px)
    let bg = makeContext(px)
    drawBackground(bg, rect: CGRect(x: 0, y: 0, width: s, height: s))
    save(bg, res.appendingPathComponent("mipmap-\(d)/ic_launcher_background.png"))

    let fg = makeContext(px)
    let safe = s * 66 / 108
    let box = CGRect(x: (s - safe) / 2, y: (s - safe) / 2, width: safe, height: safe).insetBy(dx: safe * 0.02, dy: safe * 0.02)
    drawGlyph(fg, box: box)
    save(fg, res.appendingPathComponent("mipmap-\(d)/ic_launcher_foreground.png"))

    // Ícone legado (pré-Android 8) = fundo + símbolo, cantos arredondados.
    let legacyPx = px * 48 / 108
    let lg = makeContext(legacyPx)
    let ls = CGFloat(legacyPx)
    lg.addPath(roundedRect(CGRect(x: 0, y: 0, width: ls, height: ls), ls * 0.22)); lg.clip()
    drawBackground(lg, rect: CGRect(x: 0, y: 0, width: ls, height: ls))
    drawGlyph(lg, box: CGRect(x: 0, y: 0, width: ls, height: ls).insetBy(dx: ls * 0.14, dy: ls * 0.14))
    save(lg, res.appendingPathComponent("mipmap-\(d)/ic_launcher.png"))
}
// Prévia do Android com máscara circular (como no One UI).
let prev = makeContext(432)
prev.addEllipse(in: CGRect(x: 0, y: 0, width: 432, height: 432)); prev.clip()
drawBackground(prev, rect: CGRect(x: 0, y: 0, width: 432, height: 432))
let safe: CGFloat = 432 * 66 / 108
drawGlyph(prev, box: CGRect(x: (432 - safe) / 2, y: (432 - safe) / 2, width: safe, height: safe).insetBy(dx: safe * 0.02, dy: safe * 0.02))
save(prev, root.appendingPathComponent("tools/preview-android.png"))
print("ok")
