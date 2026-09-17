// HydePark — blackens every part of the screen the active window isn't using.
// Toggle with ⌃⌥⌘F (configurable below). Menu bar icon offers opacity + quit.
import Cocoa
import Carbon

// MARK: - Configuration
let hotKeyCode: UInt32 = UInt32(kVK_ANSI_F)
let hotKeyModifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
let refreshInterval: TimeInterval = 0.12   // how often the cutout re-tracks the active window
let holePadding: CGFloat = 0               // extra transparent margin around the window
let holeCornerRadius: CGFloat = 16         // matches standard macOS window corners
let popupCoverage: CGFloat = 0.85          // a same-app window this much inside a larger one behind it is a popup, not a target
let revealFadeDuration: TimeInterval = 0.15 // fade-in when an overlay is first shown (toggle on / first visit to a Space)

#if DEBUG_LOG
let logStart = Date()
func dlog(_ msg: String) {
    let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, msg)
    if let h = FileHandle(forWritingAtPath: "/tmp/hydepark.log") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: "/tmp/hydepark.log", atomically: true, encoding: .utf8) }
}
#else
@inline(__always) func dlog(_ msg: @autoclosure () -> String) {}
#endif

// MARK: - Overlay view: black everywhere except the hole
final class MaskView: NSView {
    var hole: NSRect                  // in this view's (window) coordinates
    var lastHoleCG: CGRect? = nil     // last known target window, global CG coords (kept per Space)
    var alphaValueForMask: CGFloat = 1.0

    override init(frame: NSRect) {
        hole = NSRect(origin: .zero, size: frame.size)   // start transparent, never flash black
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.black.withAlphaComponent(alphaValueForMask).setFill()
        bounds.fill()
        if !hole.isEmpty {
            NSColor.clear.setFill()
            let r = hole.insetBy(dx: -holePadding, dy: -holePadding)
            NSBezierPath(roundedRect: r, xRadius: holeCornerRadius, yRadius: holeCornerRadius).fill()
        }
    }
}

// MARK: - Controller
final class HydePark: NSObject, NSApplicationDelegate {
    /// One overlay per screen, per Space visited while active. Overlays are ordinary windows bound to
    /// the Space they were shown on, so the window server slides them together with that Space's windows.
    private var overlaySets: [[NSWindow]] = []
    private var allWindows: [NSWindow] { overlaySets.flatMap { $0 } }
    private var windows: [NSWindow] { overlaySets.first { $0.first?.isOnActiveSpace == true } ?? [] }
    private var timer: Timer?
    private var signalSource: DispatchSourceSignal?
    #if DEBUG_MENU
    private var debugSource: DispatchSourceSignal?
    #endif
    private var statusItem: NSStatusItem!
    private var opacity: CGFloat = 1.0
    private var builtScreenFrames: [NSRect] = []
    private var followUps: [Timer] = []
    private(set) var isActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        registerHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // `kill -USR1 $(pgrep -x HydePark)` toggles too — handy for scripts.
        signal(SIGUSR1, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signalSource?.setEventHandler { [weak self] in self?.toggle() }
        signalSource?.resume()
        #if DEBUG_MENU
        // Dev aid: `kill -USR2` pops the status menu for 3 s so it can be screenshotted.
        signal(SIGUSR2, SIG_IGN)
        debugSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        debugSource?.setEventHandler { [weak self] in
            guard let self, let menu = self.statusItem.menu else { return }
            let t = Timer(timeInterval: 3, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(t, forMode: .common)
            self.statusItem.button?.performClick(nil)
        }
        debugSource?.resume()
        #endif
    }

    /// Re-launching the app while it's running (`open -a HydePark`) toggles the mask.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return false
    }

    // MARK: Menu bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Toggle Mask", action: #selector(toggle), keyEquivalent: "f")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let sliderItem = NSMenuItem()
        sliderItem.view = makeOpacityControl()
        menu.addItem(sliderItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HydePark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        let name = isActive ? "circle.lefthalf.filled" : "circle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "HydePark")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // Opacity slider with soft snapping to a few detents.
    private let snapPoints: [Double] = [25, 50, 75, 90, 100]
    private let snapTolerance: Double = 3.5
    private var opacityLabel: NSTextField!
    private var opacitySlider: NSSlider!

    private func makeOpacityControl() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 52))
        let title = NSTextField(labelWithString: "Opacity")
        title.font = .menuFont(ofSize: 13)
        title.frame = NSRect(x: 14, y: 30, width: 100, height: 18)
        opacityLabel = NSTextField(labelWithString: "")
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor
        opacityLabel.alignment = .right
        opacityLabel.frame = NSRect(x: 150, y: 30, width: 56, height: 18)
        opacitySlider = NSSlider(value: Double(opacity * 100), minValue: 10, maxValue: 100,
                                 target: self, action: #selector(opacitySliderChanged(_:)))
        opacitySlider.isContinuous = true
        opacitySlider.frame = NSRect(x: 12, y: 6, width: 196, height: 22)
        // Tick marks show the detents (slider itself doesn't hard-snap; we soft-snap in the action).
        opacitySlider.numberOfTickMarks = 0
        container.addSubview(title)
        container.addSubview(opacityLabel)
        container.addSubview(opacitySlider)
        container.addSubview(makeDetentTicks(in: opacitySlider.frame))
        updateOpacityLabel()
        return container
    }

    /// Small tick marks under the slider at each snap point.
    private func makeDetentTicks(in sliderFrame: NSRect) -> NSView {
        let ticks = NSView(frame: NSRect(x: sliderFrame.minX, y: sliderFrame.minY - 3, width: sliderFrame.width, height: 4))
        let knobInset: CGFloat = 8  // approx. half knob width, so ticks line up with knob centres
        for p in snapPoints {
            let t = CGFloat((p - opacitySlider.minValue) / (opacitySlider.maxValue - opacitySlider.minValue))
            let x = knobInset + t * (sliderFrame.width - 2 * knobInset)
            let tick = NSView(frame: NSRect(x: x - 0.5, y: 0, width: 1, height: 4))
            tick.wantsLayer = true
            tick.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            ticks.addSubview(tick)
        }
        return ticks
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        var v = sender.doubleValue
        if let snap = snapPoints.first(where: { abs($0 - v) <= snapTolerance }) {
            v = snap
            sender.doubleValue = v   // soft snap: pull the knob onto the detent
        }
        opacity = CGFloat(v.rounded()) / 100
        updateOpacityLabel()
        for w in allWindows { (w.contentView as? MaskView)?.alphaValueForMask = opacity; w.contentView?.needsDisplay = true }
    }

    private func updateOpacityLabel() {
        opacityLabel.stringValue = "\(Int((opacity * 100).rounded()))%"
    }

    // MARK: Hotkey (Carbon, no accessibility permission needed)
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { (NSApp.delegate as? HydePark)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x48594445 /* HYDE */, id: 1)
        let status = RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("HydePark: hotkey registration failed (\(status)) — is another app using ⌃⌥⌘F?") }
    }

    // MARK: Toggle
    @objc func toggle() {
        isActive ? deactivate() : activate()
    }

    private func activate() {
        isActive = true
        builtScreenFrames = NSScreen.screens.map(\.frame)
        ensureOverlaysOnActiveSpace()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        updateStatusIcon()
    }

    private func deactivate() {
        isActive = false
        timer?.invalidate(); timer = nil
        cancelFollowUps()
        allWindows.forEach { $0.orderOut(nil) }
        overlaySets.removeAll()
        builtScreenFrames = []
        updateStatusIcon()
    }

    /// Only rebuild when the screen layout really changed; macOS posts this notification
    /// for menu-bar show/hide too (e.g. entering a full-screen Space), which must not flash.
    @objc private func screensChanged() {
        dlog("screensChanged frames=\(NSScreen.screens.map(\.frame)) built=\(builtScreenFrames)")
        guard isActive else { return }
        let frames = NSScreen.screens.map(\.frame)
        if frames != builtScreenFrames {
            allWindows.forEach { $0.orderOut(nil) }
            overlaySets.removeAll()
            builtScreenFrames = frames
            ensureOverlaysOnActiveSpace()
        } else {
            refresh()
        }
    }

    /// Fires when a Space switch has finished. The overlays of both Spaces slid with their
    /// contents; all that is left is to make sure the new Space has overlays and re-track.
    @objc private func spaceChanged() {
        dlog("spaceChanged onActiveSpace=\(overlaySets.map { $0.first?.isOnActiveSpace ?? false })")
        guard isActive else { return }
        ensureOverlaysOnActiveSpace()
        scheduleFollowUps()
    }

    /// Creates (and fades in) a set of overlays for the current Space if none exists yet.
    private func ensureOverlaysOnActiveSpace() {
        if !windows.isEmpty { refresh(); return }
        let set: [NSWindow] = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .floating
            w.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]   // bound to the Space it's shown on
            w.isReleasedWhenClosed = false
            w.alphaValue = 0                       // shown only after the first cutout is placed
            let view = MaskView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.alphaValueForMask = opacity
            w.contentView = view
            return w
        }
        overlaySets.append(set)
        set.forEach { $0.orderFrontRegardless() }  // binds them to the active Space
        refreshOverlays(set)                          // place the cutout before anything is visible
        fadeIn(set)
        dlog("built overlay set #\(overlaySets.count)")
    }

    private func scheduleFollowUps() {
        cancelFollowUps()
        for delay in [0.05, 0.15, 0.3, 0.6] {
            followUps.append(Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() })
        }
    }

    private func cancelFollowUps() {
        followUps.forEach { $0.invalidate() }
        followUps.removeAll()
    }

    private func fadeIn(_ set: [NSWindow]) {
        dlog("REVEAL")
        guard revealFadeDuration > 0 else { set.forEach { $0.alphaValue = 1 }; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = revealFadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            set.forEach { $0.animator().alphaValue = 1 }
        }
    }

    // MARK: Tracking the active window
    private typealias WindowList = [[String: Any]]

    private func onScreenWindows() -> WindowList? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? WindowList
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Frontmost window of the frontmost app, in CG global coordinates (origin top-left of primary screen).
    private func activeWindowBounds(in list: WindowList) -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        // List is ordered front-to-back; layer-0 windows of the app, frontmost first.
        let candidates: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let r = Self.bounds(of: info),
                  r.width > 50, r.height > 50 // skip tiny helper windows
            else { return nil }
            return r
        }
        // Transient popups (Chrome's tab hover cards, omnibox suggestions, tooltips, autocomplete lists)
        // are plain layer-0 windows drawn in front of the window that spawned them, so they would win
        // the "frontmost" test. They sit inside their parent's bounds, so skip any window that a larger
        // window of the same app behind it (almost) entirely covers, and keep the cutout on the parent.
        for (i, r) in candidates.enumerated() {
            let isPopup = candidates[(i + 1)...].contains { parent in
                parent.width * parent.height > r.width * r.height && Self.coverage(of: r, by: parent) >= popupCoverage
            }
            if !isPopup { return r }
        }
        return nil
    }

    /// Fraction of `r`'s area that lies inside `other` (0 = disjoint, 1 = fully contained).
    private static func coverage(of r: CGRect, by other: CGRect) -> CGFloat {
        let inter = r.intersection(other)
        guard !inter.isNull, r.width > 0, r.height > 0 else { return 0 }
        return (inter.width * inter.height) / (r.width * r.height)
    }

    /// Where the window server currently draws one of our overlays. During a Space slide this moves
    /// together with every other window on that Space, so a hole computed relative to it stays put.
    private func overlayBounds(of w: NSWindow, in list: WindowList) -> CGRect {
        let num = w.windowNumber
        if let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == num }), let r = Self.bounds(of: info) {
            return r
        }
        return homeBounds(of: w)
    }

    @objc private func refresh() { refreshOverlays(windows) }

    private func homeBounds(of w: NSWindow) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: w.frame.minX, y: primaryHeight - w.frame.maxY, width: w.frame.width, height: w.frame.height)
    }

    private func refreshOverlays(_ set: [NSWindow]) {
        guard isActive, !set.isEmpty, let list = onScreenWindows() else { return }
        let target = activeWindowBounds(in: list)
        dlog("refresh front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") target=\(target.map { "\($0)" } ?? "nil")")
        for w in set {
            guard let view = w.contentView as? MaskView else { continue }
            let hole = target ?? view.lastHoleCG   // keep last cutout if app has no window (e.g. Finder desktop)
            view.lastHoleCG = hole
            var viewHole = view.bounds             // no window to focus on -> don't black anything out
            if let h = hole {
                let ob = overlayBounds(of: w, in: list)
                // CG global -> overlay-local (CG, top-left) -> view coords (bottom-left)
                let localCG = CGRect(x: h.minX - ob.minX, y: h.minY - ob.minY, width: h.width, height: h.height)
                let local = NSRect(x: localCG.minX, y: ob.height - localCG.maxY, width: localCG.width, height: localCG.height)
                viewHole = local.intersection(view.bounds)
                dlog("  overlay=\(ob) local=\(local)")
            }
            if viewHole != view.hole {
                dlog("  viewHole -> \(viewHole)")
                view.hole = viewHole
                view.needsDisplay = true
            }
        }
    }
}

// MARK: - Entry
let app = NSApplication.shared
let delegate = HydePark()
app.delegate = delegate
app.run()
