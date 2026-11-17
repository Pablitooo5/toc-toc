// Toc Toc — quand Claude a répondu et que personne ne touche l'ordinateur depuis une minute,
// le mini Claude arrive sur le côté de l'écran, fait des signaux avec sa lampe, puis toque à la vitre
// (l'écran tremble) jusqu'à ce que la souris ou le clavier bouge. Il ne revient pas pour la même réponse.
import Cocoa
import WebKit
import ScreenCaptureKit
import IOKit
import CoreAudio

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: OverlayPanel!
    private var web: WKWebView!
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var delayItems: [NSMenuItem] = []
    private var pageReady = false

    private var showActive = false
    private var showStartedAt = Date()
    private var isDemo = false
    private var jsPhase = "idle"
    private var handledStamp: Double = 0
    private var lastMicAt: Double = 0
    private var micWasOn = false
    private var micUser = "?"
    private var capturing = false
    private var sounds: [String: NSSound] = [:]
    private var playing: [NSSound] = []

    private let defaults = UserDefaults.standard
    private let home = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/toc-toc")
    private var waitingDir: String { (home as NSString).appendingPathComponent("waiting") }
    private var demoFlag: String { (home as NSString).appendingPathComponent("demo") }
    private var logPath: String { (home as NSString).appendingPathComponent("toc.log") }
    private var handledPath: String { (home as NSString).appendingPathComponent("annonce") }
    private func saveHandled() { try? String(handledStamp).write(toFile: handledPath, atomically: true, encoding: .utf8) }

    private var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }
    private var soundOn: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sound") }
    }
    private var delay: Int {
        get { let v = defaults.integer(forKey: "delay"); return v > 0 ? v : 60 }
        set { defaults.set(newValue, forKey: "delay") }
    }

    // MARK: - Démarrage

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: waitingDir, withIntermediateDirectories: true)
        // Les réponses déjà annoncées restent annoncées, même après un redémarrage de l'app ou du Mac.
        // Au tout premier lancement, celles qui attendent déjà ne sont pas annoncées.
        if let s = try? String(contentsOfFile: handledPath, encoding: .utf8),
           let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            handledStamp = v
        } else {
            handledStamp = waitingInfo()?.newest ?? 0
            saveHandled()
        }
        let frame = currentScreen().frame

        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar            // au-dessus des fenêtres, même d'une vidéo en plein écran
        panel.ignoresMouseEvents = true      // les clics traversent toujours
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "toc")
        web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        panel.contentView = web
        if let url = Bundle.main.url(forResource: "overlay", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        if let url = Bundle.main.url(forResource: "knock", withExtension: "wav") {
            sounds["knock"] = NSSound(contentsOf: url, byReference: false)
        }

        buildMenu()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        log("démarrage, délai \(delay) s, vraie vibration \(CGPreflightScreenCaptureAccess() ? "autorisée" : "non autorisée")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
    }

    // MARK: - Messages venant de l'animation

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let value = body["value"] as? String ?? ""
        switch type {
        case "sfx":
            if soundOn { play(value) }
        case "needShot":
            sendShot()
        case "phase":
            jsPhase = value
            if value == "done" {
                showActive = false
                isDemo = false
                log("reparti")
            }
        default:
            break
        }
    }

    private func play(_ name: String) {
        playing.removeAll { !$0.isPlaying }
        guard let s = sounds[name]?.copy() as? NSSound else { return }
        s.volume = 0.8
        s.play()
        playing.append(s)
    }

    /// Une photo fraîche de l'écran pour le faire trembler à chaque série de coups.
    /// Sans l'autorisation « Enregistrement de l'écran », l'animation fait vibrer les bords à la place.
    private func sendShot() {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else { js("toc.setShot(null)"); return }
        capturing = true
        Task { @MainActor in
            let shot = await self.captureScreen()
            self.capturing = false
            self.js(shot.map { "toc.setShot('\($0)')" } ?? "toc.setShot(null)")
        }
    }

    // MARK: - Boucle

    private func tick() {
        guard pageReady else { return }
        let fm = FileManager.default
        // Micro allumé (tu dictes à Claude, tu es en appel…) = tu es là : ça compte comme de l'activité.
        let micOn = micInUse()
        let nowS = Date().timeIntervalSince1970
        if micOn { lastMicAt = nowS }
        if micOn != micWasOn {
            micWasOn = micOn
            log(micOn ? "micro allumé (\(micUser)) : Toc Toc ne vient pas" : "micro éteint")
        }
        let idle = min(systemIdleSeconds(), nowS - lastMicAt)

        if fm.fileExists(atPath: demoFlag) {
            try? fm.removeItem(atPath: demoFlag)
            if !showActive { startShow(demo: true, waited: 64, title: "Démo", others: 0) }
            return
        }

        if showActive {
            if Date().timeIntervalSince(showStartedAt) > 4 * 3600 || screenLocked() {   // garde-fous
                stopNow()
                return
            }
            // En vrai : il repart dès que tu bouges. En démo : seulement une fois qu'il toque.
            let cancellable = isDemo ? ["knock", "lamp"].contains(jsPhase) : ["arrive", "signals", "knock", "lamp"].contains(jsPhase)
            let replied = !isDemo && waitingInfo() == nil
            if cancellable && (idle < 1.0 || replied) { js("toc.userBack()") }
            return
        }

        followScreen()
        guard !paused, !screenLocked(), let info = waitingInfo() else { return }
        let now = Date().timeIntervalSince1970
        let d = Double(delay)
        if info.newest > handledStamp && now - info.newest >= d && idle >= d {
            handledStamp = info.newest       // une seule fois par réponse de Claude
            saveHandled()
            startShow(demo: false, waited: now - info.newest, title: info.title, others: info.others)
        }
    }

    private func startShow(demo: Bool, waited: Double, title: String, others: Int) {
        isDemo = demo
        showActive = true
        showStartedAt = Date()
        jsPhase = "arrive"
        followScreen()
        log(demo ? "démo" : "toc toc : « \(title) » attend depuis \(Int(waited)) s")
        js("toc.trigger(\(Int(waited)), \(jsString(title)), \(others))")
    }

    private func stopNow() {
        js("toc.reset()")
        showActive = false
        isDemo = false
    }

    /// La conversation Claude la plus récente qui attend une réponse : quand elle a fini, son titre,
    /// et combien d'autres conversations attendent aussi. nil si aucune n'attend.
    /// Chaque fichier contient l'heure sur la première ligne et le titre sur la deuxième.
    private func waitingInfo() -> (newest: Double, title: String, others: Int)? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: waitingDir) else { return nil }
        let now = Date().timeIntervalSince1970
        var best: (newest: Double, title: String)?
        var count = 0
        for name in names where !name.hasPrefix(".") {
            let path = (waitingDir as NSString).appendingPathComponent(name)
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = lines.first, let t = Double(first) else { try? fm.removeItem(atPath: path); continue }
            if now - t > 12 * 3600 { try? fm.removeItem(atPath: path); continue }
            count += 1
            let title = lines.count > 1 && !lines[1].isEmpty ? lines[1] : "Une conversation"
            if best == nil || t > best!.newest { best = (t, title) }
        }
        guard let b = best else { return nil }
        return (b.newest, b.title, count - 1)
    }

    private func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// Secondes depuis le dernier mouvement de souris ou appui sur une touche.
    @available(macOS 14.2, *)
    private func processName(_ id: AudioObjectID) -> String {
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var s = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid) == noErr, pid > 0 else { return "?" }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.bundleIdentifier ?? app.localizedName ?? "pid \(pid)"
        }
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let name = String(cString: buf)
        return name.isEmpty ? "pid \(pid)" : name
    }

    /// Une app enregistre-t-elle le micro en ce moment ? (aucune autorisation nécessaire : on ne lit pas le son)
    private func micInUse() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if #available(macOS 14.2, *) {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            if AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr {
                var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr {
                    var input = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
                    for id in ids {
                        var running: UInt32 = 0
                        var s = UInt32(MemoryLayout<UInt32>.size)
                        guard AudioObjectGetPropertyData(id, &input, 0, nil, &s, &running) == noErr, running != 0 else { continue }
                        // « Dis Siri » écoute en permanence : ce n'est pas toi qui parles.
                        let who = processName(id)
                        if who.lowercased().contains("corespeech") { continue }
                        micUser = who
                        return true
                    }
                    return false
                }
            }
        }
        // Avant macOS 14.2 : un appareil qui a une entrée (micro) et qui tourne
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return false }
        for dev in devices {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &streams, 0, nil, &ss) == noErr, ss > 0 else { continue }
            var run = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &run, 0, nil, &s, &running) == noErr, running != 0 { return true }
        }
        return false
    }

    private func systemIdleSeconds() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let ns = dict["HIDIdleTime"] as? NSNumber else { return 0 }
        return ns.doubleValue / 1_000_000_000
    }

    private func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func followScreen() {
        let frame = currentScreen().frame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Photo de l'écran (sans cette fenêtre). Elle reste sur le Mac : jamais enregistrée ni envoyée.
    private func captureScreen() async -> String? {
        let screen = panel.screen ?? currentScreen()
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == num.uint32Value }) else { return nil }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
            return "data:image/jpeg;base64," + data.base64EncodedString()
        } catch {
            log("photo de l'écran impossible : \(error.localizedDescription)")
            return nil
        }
    }

    private func js(_ code: String) {
        web.evaluateJavaScript(code, completionHandler: nil)
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile()
        } else {
            try? text.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Menu (icône 🔦 dans la barre des menus)

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔦"
        let menu = NSMenu()
        let title = NSMenuItem(title: "Toc Toc", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(item("Lancer la démo (dans 3 s)", #selector(runDemo)))
        pauseItem = item("En pause", #selector(togglePause))
        menu.addItem(pauseItem)
        soundItem = item("Son (toc toc)", #selector(toggleSound))
        menu.addItem(soundItem)

        let delayMenu = NSMenu()
        for s in [30, 60, 120, 300] {
            let it = item(s < 60 ? "\(s) secondes" : "\(s / 60) minute\(s >= 120 ? "s" : "")", #selector(chooseDelay(_:)))
            it.tag = s
            delayMenu.addItem(it)
            delayItems.append(it)
        }
        let delayParent = NSMenuItem(title: "Venir après…", action: nil, keyEquivalent: "")
        delayParent.submenu = delayMenu
        menu.addItem(delayParent)

        captureItem = item("Faire vraiment trembler l'écran : autoriser…", #selector(askCapture))
        menu.addItem(captureItem)
        menu.addItem(item("Le renvoyer maintenant", #selector(sendAway)))
        menu.addItem(.separator())
        menu.addItem(item("Quitter", #selector(quit), key: "q"))
        statusItem.menu = menu
        refreshMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func refreshMenu() {
        pauseItem.state = paused ? .on : .off
        soundItem.state = soundOn ? .on : .off
        delayItems.forEach { $0.state = $0.tag == delay ? .on : .off }
        captureItem.isHidden = CGPreflightScreenCaptureAccess()
    }

    @objc private func runDemo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.showActive else { return }
            self.startShow(demo: true, waited: 64, title: "Démo", others: 0)
        }
    }

    @objc private func togglePause() { paused.toggle(); refreshMenu() }
    @objc private func toggleSound() { soundOn.toggle(); refreshMenu() }
    @objc private func chooseDelay(_ sender: NSMenuItem) { delay = sender.tag; refreshMenu() }

    @objc private func askCapture() {
        // Affiche la demande de macOS ; c'est la personne qui décide dans Réglages Système.
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refreshMenu()
    }

    @objc private func sendAway() {
        if showActive { js("toc.userBack()") }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
