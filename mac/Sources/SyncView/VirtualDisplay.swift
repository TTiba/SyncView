import CoreGraphics
import CGVirtualDisplayPrivate
import Foundation

/// Escala da interface no tablet. `pixels / scale` = tamanho lógico ("parece com").
enum DisplayScale: String, CaseIterable {
    case retina = "retina"        // 2.0  → 1480×924 no S9 Ultra (mesma densidade do MacBook)
    case moreSpace = "moreSpace"  // 1.667 → 1776×1110
    case maxSpace = "maxSpace"    // 1.5  → 1974×1232

    var factor: Double {
        switch self {
        case .retina: return 2.0
        case .moreSpace: return 5.0 / 3.0
        case .maxSpace: return 1.5
        }
    }

    var label: String {
        switch self {
        case .retina: return "Padrão (Retina, mais nítido)"
        case .moreSpace: return "Mais espaço"
        case .maxSpace: return "Máximo de espaço"
        }
    }

    /// Tamanho lógico (pontos) para uma tela de `w`×`h` pixels. Sempre par.
    func logicalSize(pixelWidth w: Int, pixelHeight h: Int) -> (Int, Int) {
        func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
        return (even(Double(w) / factor), even(Double(h) / factor))
    }
}

/// Monitor virtual criado via CGVirtualDisplay. Enquanto o objeto viver, o
/// macOS enxerga um monitor real (aparece em Ajustes > Monitores).
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    private(set) var scale: DisplayScale

    var displayID: CGDirectDisplayID { display.displayID }

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: resolução física do tablet (paisagem).
    ///   - refreshRate: Hz desejados (120 no S9 Ultra).
    ///   - diagonalInches: usado só para o macOS calcular o tamanho físico.
    init?(name: String, serial: UInt32, pixelWidth: Int, pixelHeight: Int,
          refreshRate: Double, diagonalInches: Double, scale: DisplayScale) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.scale = scale

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        // Espaço para o maior modo HiDPI (backing = 2× o tamanho lógico).
        let maxLogical = DisplayScale.maxSpace.logicalSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        descriptor.maxPixelsWide = UInt32(max(maxLogical.0 * 2, pixelWidth))
        descriptor.maxPixelsHigh = UInt32(max(maxLogical.1 * 2, pixelHeight))
        let diagPx = (Double(pixelWidth * pixelWidth + pixelHeight * pixelHeight)).squareRoot()
        let mmPerPx = diagonalInches * 25.4 / diagPx
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) * mmPerPx,
                                              height: Double(pixelHeight) * mmPerPx)
        // IDs fixos → o macOS lembra a posição do monitor entre conexões.
        descriptor.vendorID = 0x5356 // "SV"
        descriptor.productID = 0x5339 // "S9"
        descriptor.serialNum = serial
        descriptor.terminationHandler = { _, _ in
            Log.info("Monitor virtual encerrado pelo sistema")
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0 else {
            Log.error("CGVirtualDisplay não retornou displayID")
            return nil
        }
        self.display = display

        guard applyModes() else { return nil }
        Log.info("Monitor virtual criado: id=\(display.displayID) \(pixelWidth)×\(pixelHeight) @\(refreshRate)Hz")
    }

    private func applyModes() -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        var modes: [CGVirtualDisplayMode] = []
        for s in DisplayScale.allCases {
            let (w, h) = s.logicalSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            modes.append(CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: refreshRate))
        }
        // Modo 1:1 (sem HiDPI) também disponível em Ajustes > Monitores.
        modes.append(CGVirtualDisplayMode(width: UInt32(pixelWidth), height: UInt32(pixelHeight), refreshRate: refreshRate))
        settings.modes = modes
        if !display.apply(settings) {
            Log.error("applySettings falhou")
            return false
        }
        return true
    }

    /// Seleciona o modo HiDPI desejado. O monitor recém-criado leva alguns
    /// ms para expor seus modos; tentamos de novo sem bloquear a main thread
    /// (ela é a fila do CGVirtualDisplay).
    func select(scale: DisplayScale, attempts: Int = 30, completion: ((Bool) -> Void)? = nil) {
        self.scale = scale
        if selectNow(scale: scale, logMissing: attempts <= 1) { completion?(true); return }
        guard attempts > 1 else { completion?(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { completion?(false); return }
            self.select(scale: scale, attempts: attempts - 1, completion: completion)
        }
    }

    /// Uma tentativa síncrona.
    @discardableResult
    func selectNow(scale: DisplayScale, logMissing: Bool = true) -> Bool {
        self.scale = scale
        let (lw, lh) = scale.logicalSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard let mode = findMode(logicalWidth: lw, logicalHeight: lh, hiDPI: true) else {
            if logMissing { Log.error("Modo \(lw)×\(lh) HiDPI não encontrado. Modos: \(describeModes())") }
            return false
        }
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.width == mode.width, current.pixelWidth == mode.pixelWidth,
           abs(current.refreshRate - mode.refreshRate) < 0.5 {
            return true
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else {
            Log.error("CGCompleteDisplayConfiguration erro \(err.rawValue)")
            return false
        }
        Log.info("Modo aplicado: \(mode.width)×\(mode.height) (pixels \(mode.pixelWidth)×\(mode.pixelHeight)) @\(mode.refreshRate)Hz")
        return true
    }

    private func allModes() -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
    }

    private func findMode(logicalWidth: Int, logicalHeight: Int, hiDPI: Bool) -> CGDisplayMode? {
        let candidates = allModes().filter {
            $0.width == logicalWidth && $0.height == logicalHeight &&
            (hiDPI ? $0.pixelWidth > $0.width : $0.pixelWidth == $0.width)
        }
        return candidates.max { $0.refreshRate < $1.refreshRate }
    }

    func describeModes() -> String {
        allModes().map { "\($0.width)×\($0.height)[\($0.pixelWidth)×\($0.pixelHeight)]@\(Int($0.refreshRate))" }
            .joined(separator: ", ")
    }

    /// Retângulo do monitor no espaço global de coordenadas (pontos).
    var bounds: CGRect { CGDisplayBounds(displayID) }

    var currentRefreshRate: Double { CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0 }
}
