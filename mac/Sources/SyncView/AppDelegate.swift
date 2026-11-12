import AppKit
import ServiceManagement

/// App de barra de menus (sem ícone no Dock).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        controller.onUpdate = { [weak self] in self?.refreshIcon() }
        controller.start()
        refreshIcon()

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !InputInjector.isTrusted { InputInjector.requestTrust() }
        Log.info("SyncView iniciado")
    }

    private func refreshIcon() {
        let symbol = controller.isStreaming ? "rectangle.on.rectangle.angled.fill" : "rectangle.on.rectangle.angled"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SyncView")
        statusItem.button?.appearsDisabled = !controller.isStreaming
        if menu.highlightedItem == nil, statusItem.button?.isHighlighted == true { rebuildMenu() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func statusText() -> String {
        if controller.isStreaming { return "● Transmitindo para \(controller.hello?.deviceName ?? "tablet")" }
        switch controller.adbState {
        case .adbMissing: return "adb não encontrado (brew install android-platform-tools)"
        case .noDevice: return "Aguardando tablet no cabo USB…"
        case .unauthorized: return "Autorize a depuração USB na tela do tablet"
        case .ready(_, let model): return "\(model) conectado — abrindo app no tablet…"
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(disabled(statusText()))
        if controller.isStreaming, let d = controller.display {
            let (lw, lh) = Settings.scale.logicalSize(pixelWidth: d.pixelWidth, pixelHeight: d.pixelHeight)
            menu.addItem(disabled("\(d.pixelWidth)×\(d.pixelHeight) px · parece \(lw)×\(lh) · \(Int(d.currentRefreshRate)) Hz"))
            var s = "\(controller.statFPS) fps · \(String(format: "%.1f", controller.statMbps)) Mbps"
            if controller.statDropped > 0 { s += " · \(controller.statDropped) quadros pulados" }
            menu.addItem(disabled(s))
        }
        if controller.adb.needsManualReplug {
            menu.addItem(disabled("⚠︎ O cabo travou: tire e coloque o cabo do tablet"))
            menu.addItem(disabled("   (ou clique em Reconectar; se repetir, troque o cabo)"))
        }
        if let cap = controller.unstableCapMbps {
            menu.addItem(disabled("⚠︎ Cabo instável: taxa reduzida para \(cap) Mbps até estabilizar"))
        }
        if controller.isStreaming, controller.usb2Limited {
            menu.addItem(disabled("⚠︎ Cabo USB 2.0: qualidade limitada a \(Controller.usb2MaxMbps) Mbps (use um cabo USB 3)"))
        }
        if let err = controller.lastError { menu.addItem(disabled("⚠︎ \(err)")) }
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(action("⚠︎ Permitir Gravação de Tela…", #selector(openScreenRecording)))
        }
        if !InputInjector.isTrusted {
            menu.addItem(action("⚠︎ Permitir Acessibilidade (toque/caneta)…", #selector(openAccessibility)))
        }

        menu.addItem(.separator())
        let scaleMenu = NSMenu()
        for s in DisplayScale.allCases {
            let it = action(s.label, #selector(pickScale(_:)))
            it.representedObject = s.rawValue
            it.state = Settings.scale == s ? .on : .off
            scaleMenu.addItem(it)
        }
        menu.addItem(submenu("Tamanho da interface", scaleMenu))

        let qMenu = NSMenu()
        for (label, mbps) in [("Equilibrada (50 Mbps)", 50), ("Alta (100 Mbps)", 100), ("Máxima (200 Mbps)", 200)] {
            let it = action(label, #selector(pickBitrate(_:)))
            it.tag = mbps
            it.state = Settings.bitrateMbps == mbps ? .on : .off
            qMenu.addItem(it)
        }
        menu.addItem(submenu("Qualidade", qMenu))

        let cMenu = NSMenu()
        for c in Codec.allCases {
            let it = action(c.label, #selector(pickCodec(_:)))
            it.representedObject = c.rawValue
            it.state = Settings.codec == c ? .on : .off
            cMenu.addItem(it)
        }
        menu.addItem(submenu("Codec", cMenu))

        let inv = action("Inverter direção da rolagem", #selector(toggleInvert))
        inv.state = Settings.invertScroll ? .on : .off
        menu.addItem(inv)

        let login = action("Abrir ao iniciar sessão", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Organizar monitores…", #selector(openDisplays)))
        menu.addItem(action("Reconectar", #selector(reconnect)))
        menu.addItem(action("Abrir log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair do SyncView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }
    private func action(_ t: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }
    private func submenu(_ t: String, _ m: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        it.submenu = m
        return it
    }

    @objc private func pickScale(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = DisplayScale(rawValue: raw) else { return }
        controller.applyScale(s)
    }
    @objc private func pickBitrate(_ sender: NSMenuItem) {
        Settings.bitrateMbps = sender.tag
        controller.restartSession()
    }
    @objc private func pickCodec(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Codec(rawValue: raw) else { return }
        Settings.codec = c
        controller.restartSession()
    }
    @objc private func toggleInvert() { controller.setInvertScroll(!Settings.invertScroll) }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.error("Abrir ao iniciar sessão: \(error.localizedDescription)")
        }
    }
    @objc private func reconnect() {
        controller.adb.restartServer(reason: "menu Reconectar")
        controller.restartSession()
    }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func openDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
    @objc private func openScreenRecording() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func openAccessibility() {
        InputInjector.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
