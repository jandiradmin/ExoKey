import UIKit

/// One key on screen.
final class KeyCap: UIControl {
    /// How far outside its drawn shape the key still takes a touch (half the gap to each neighbour).
    var hitOutset = UIEdgeInsets.zero
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        CGRect(x: -hitOutset.left, y: -hitOutset.top, width: bounds.width + hitOutset.left + hitOutset.right,
               height: bounds.height + hitOutset.top + hitOutset.bottom).contains(p)
    }
    let key: Key
    let row: Int
    private let label = UILabel()
    private let icon = UIImageView()
    private let hint = UILabel()
    var pressed = false { didSet { if KeyboardView.animations || !pressed { updateLook() } } }

    init(key: Key, row: Int) {
        self.key = key
        self.row = row
        super.init(frame: .zero)
        // VoiceOver and the test robot (ios/UITests) find keys by name
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        accessibilityLabel = debugName
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        icon.contentMode = .center
        icon.tintColor = .label
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .right
        if case .char = key.kind, let a = key.alts.first { hint.text = a }
        addSubview(label)
        addSubview(icon)
        addSubview(hint)
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    var debugName: String {
        switch key.kind {
        case .char(let s): return s
        case .space: return "␣"
        case .backspace: return "⌫"
        case .shift: return "⇧"
        case .ret: return "⏎"
        default: return "\(key.kind)"
        }
    }

    var isSpecial: Bool {
        switch key.kind {
        case .char: return false
        case .space: return false
        default: return true
        }
    }

    private static var fonts: [CGFloat: UIFont] = [:]
    private static var images: [String: UIImage] = [:]
    private var shownTitle = "", shownSize: CGFloat = 0, shownIcon = ""

    /// Changing a label is not free (layout, redraw): only when the text really changes.
    func setTitle(_ s: String, size: CGFloat = 24) {
        guard s != shownTitle || size != shownSize else { return }
        shownTitle = s; shownSize = size; shownIcon = ""
        if let f = Self.fonts[size] { label.font = f } else { let f = UIFont.systemFont(ofSize: size); Self.fonts[size] = f; label.font = f }
        label.text = s
        icon.image = nil
    }

    func setIcon(_ name: String) {
        guard name != shownIcon else { return }
        shownIcon = name; shownTitle = ""
        label.text = nil
        if let i = Self.images[name] { icon.image = i; return }
        let i = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        Self.images[name] = i
        icon.image = i
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        icon.frame = bounds
        hint.frame = CGRect(x: 0, y: 2, width: bounds.width - 4, height: 12)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func updateLook() {
        let normal: UIColor = isSpecial ? KeyboardView.specialColor : KeyboardView.keyColor
        let down: UIColor = isSpecial ? KeyboardView.keyColor : KeyboardView.specialColor
        backgroundColor = pressed ? down : normal
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateLook()
    }
}

/// The whole keyboard: draws the keys and handles all touches itself (fast multi-touch typing).
final class KeyboardView: UIView {
    static let keyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    static let specialColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.26, alpha: 1) : UIColor(red: 0.69, green: 0.71, blue: 0.75, alpha: 1) }

    enum Shift { case off, once, locked }

    /// Visual effects on a key press (the letter above the finger, the key highlight). Off by default: plain and light.
    static var animations: Bool { KLog.defaults.object(forKey: "animations") as? Bool ?? false }

    weak var controller: UIInputViewController?
    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    var lang: KeyboardLang = KeyboardLang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .ru {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang"); controller?.primaryLanguage = lang.locale; rebuild() }
    }
    var showGlobe = false { didSet { if showGlobe != oldValue { rebuild() } } }
    private var symbolsMode = false
    private var shift = Shift.off
    private var shiftIsAuto = false
    private var lastShiftTap = Date.distantPast
    private var lastWasSpace = false

    private var caps: [[KeyCap]] = []
    private var keyTop: CGFloat = 0
    private var needNeighbors = true
    private var lastLayoutSize = CGSize.zero
    private var keyRowH: CGFloat = 1

    // touch state
    private final class Track {
        var cap: KeyCap
        let start: CGPoint
        var longTimer: Timer?
        var repeatTimer: Timer?
        var popup: AltPopup?
        var swiped = false
        var done = false          // already typed (a faster finger came down)
        var order = 0
        var downAt: TimeInterval = 0     // when the finger touched the glass (not when iOS delivered it)
        var last: CGPoint = .zero        // where this finger was seen last (to tell it from another finger)
        var cursorMode = false           // space held: sliding the finger moves the cursor
        var moves = 0                    // separate small steps of the finger (a slide), not one jump
        var cursorX: CGFloat = 0         // finger position at the last cursor step
        init(cap: KeyCap, start: CGPoint) { self.cap = cap; self.start = start }
        func stop() { longTimer?.invalidate(); repeatTimer?.invalidate() }
    }
    private var tracks: [ObjectIdentifier: Track] = [:]
    private var touchCount = 0
    private var lastDown: (p: CGPoint, at: TimeInterval)?
    private var lastOtherDown: TimeInterval = 0
    private let preview = PreviewBalloon()
    private let bar = SuggestionBar()
    static let barHeight: CGFloat = 46      // words row; the phrase row comes back when there is a phrase source for Russian

    init(controller: UIInputViewController) {
        self.controller = controller
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        applyGapFill()
        controller.primaryLanguage = lang.locale
        var expected = CACurrentMediaTime() + 0.05
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let late = max(0, now - expected)
            Speed.add(.stall, late)
            // the keyboard froze: touches during a freeze can be thrown away by iOS
            if late > 0.15, late < 30 { KLog.write("MAIN STALL \(Int(late * 1000))ms after \(Speed.lastAction)") }
            expected = now + 0.05
        }
        bar.onPick = { [weak self] in self?.pick($0) }
        bar.onChip = { [weak self] in self?.applyChip() }
        bar.onSettings = { [weak self] in self?.openSettings() }
        bar.onPhrase = { [weak self] in self?.pickPhrase($0) }
        KLog.write("start fullAccess=\(controller.hasFullAccess) group=\(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KLog.group) != nil)")
        KLog.defaults.removeObject(forKey: "logLines")      // the old log kept in settings (heavy)
        KLog.write("mode: \(Self.simple ? "simple" : "full")")
        addSubview(bar)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var stallTimer: Timer?

    /// iOS ignores a touch on a fully transparent point of a keyboard extension before any view is asked
    /// (one developer measured 7 lost letters per 100 with a clear background, ~1 with Apple's keyboard).
    /// The gaps between keys were clear: a light tap at a key's edge never reached the keyboard.
    /// A barely visible fill makes every point of the keyboard touchable.
    /// Checked on the iPhone (2026-11-09): with the fill, every touch reached the keys.
    private func applyGapFill() {
        backgroundColor = UIColor.black.withAlphaComponent(0.02)
    }

    deinit { stallTimer?.invalidate() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stallTimer?.invalidate() }
    }

    // MARK: building

    private func rebuild() {
        caps.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        var rows: [[Key]] = [Layouts.digits]
        rows += symbolsMode ? Layouts.symbols : Layouts.letters(lang)
        rows.append(Layouts.bottom(symbolsMode: symbolsMode, globe: showGlobe))
        caps = rows.enumerated().map { r, row in row.map { KeyCap(key: $0, row: r) } }
        for cap in caps.flatMap({ $0 }) {
            addSubview(cap)
            cap.addTarget(self, action: #selector(capDown(_:event:)), for: .touchDown)
            cap.addTarget(self, action: #selector(capDrag(_:event:)), for: [.touchDragInside, .touchDragOutside])
            cap.addTarget(self, action: #selector(capUp(_:event:)), for: [.touchUpInside, .touchUpOutside])
            cap.addTarget(self, action: #selector(capCancel(_:event:)), for: .touchCancel)
        }
        bringSubviewToFront(preview)
        refreshTitles()
        setNeedsLayout()
        needNeighbors = true
    }

    private func refreshTitles() {
        let upper = shift != .off
        for cap in caps.flatMap({ $0 }) {
            switch cap.key.kind {
            case .char(let s): cap.setTitle(upper && !symbolsMode ? s.uppercased() : s, size: cap.key.isDigit ? 22 : 24)
            case .shift: cap.setIcon(shift == .locked ? "capslock.fill" : shift == .once ? "shift.fill" : "shift")
            case .backspace: cap.setIcon("delete.left")
            case .symbols: cap.setTitle("#+=", size: 16)
            case .letters: cap.setTitle(lang == .ru ? "АБВ" : "ABC", size: 16)
            case .globe: cap.setIcon("globe")
            case .space: cap.setTitle("‹  \(lang.title)  ›", size: 15)
            case .ret: cap.setIcon("return")
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        bar.frame = CGRect(x: 0, y: 0, width: w, height: Self.barHeight)
        let side: CGFloat = 3, top: CGFloat = Self.barHeight + 2, bottom: CGFloat = 4
        let rowH = (h - top - bottom) / CGFloat(max(1, caps.count))
        keyTop = top
        keyRowH = rowH
        // the first layout pass is full-screen, before the keyboard gets its height: redo neighbours on resize
        if bounds.size != lastLayoutSize { lastLayoutSize = bounds.size; needNeighbors = true }
        defer {
            updateHitAreas()
            if needNeighbors {
                needNeighbors = false
                updateNeighbors()
                // key rectangles for the typing map (ios/typing_map.py)
                let rects = caps.flatMap { $0 }.map { c in
                    "\(c.debugName)=\(Int(c.frame.minX)),\(Int(c.frame.minY)),\(Int(c.frame.width)),\(Int(c.frame.height))"
                }
                KLog.write("keys \(symbolsMode ? "sym" : lang.rawValue) \(Int(bounds.width))x\(Int(bounds.height)) " + rects.joined(separator: " "))
            }
        }
        let gapX: CGFloat = w > 600 ? 10 : 6, gapY: CGFloat = rowH > 50 ? 12 : 10
        let g = Layouts.grid
        let unit = (w - 2 * side) / g
        for (r, row) in caps.enumerated() {
            let fixed = row.filter { $0.key.kind != .space }.reduce(0) { $0 + $1.key.width }
            let flex: CGFloat = row.contains { $0.key.kind == .space } ? max(3, g - fixed) : 0
            let total = fixed + flex
            let u = total > g ? unit * g / total : unit
            // ⇧ and ⌫ stay at the edges; the letters between them are centered
            let edges = row.first?.key.kind == .shift && row.last?.key.kind == .backspace
            var x = side + (g * unit - total * u) / 2
            if edges, total < g {
                let inner = row.dropFirst().dropLast()
                let innerW = inner.reduce(0) { $0 + $1.key.width } * u
                let sw = row.first!.key.width * u, bw = row.last!.key.width * u
                row.first!.frame = CGRect(x: side + gapX / 2, y: top + CGFloat(r) * rowH + gapY / 2, width: sw - gapX, height: rowH - gapY)
                row.last!.frame = CGRect(x: w - side - bw + gapX / 2, y: top + CGFloat(r) * rowH + gapY / 2, width: bw - gapX, height: rowH - gapY)
                x = (w - innerW) / 2
                for cap in inner {
                    cap.frame = CGRect(x: x + gapX / 2, y: top + CGFloat(r) * rowH + gapY / 2, width: cap.key.width * u - gapX, height: rowH - gapY)
                    x += cap.key.width * u
                }
                continue
            }
            for cap in row {
                let kw = (cap.key.kind == .space ? flex : cap.key.width) * u
                cap.frame = CGRect(x: x + gapX / 2, y: top + CGFloat(r) * rowH + gapY / 2, width: kw - gapX, height: rowH - gapY)
                x += kw
            }
        }
    }

    /// The key under a finger: the row by height, then the nearest key in it (gaps and margins count too).
    private func cap(at p: CGPoint) -> KeyCap? {
        guard !caps.isEmpty else { return nil }
        guard p.y >= Self.barHeight else { return nil }
        let r = min(caps.count - 1, max(0, Int((p.y - keyTop) / keyRowH)))
        return caps[r].min { abs($0.frame.midX - p.x) - $0.frame.width / 2 < abs($1.frame.midX - p.x) - $1.frame.width / 2 }
    }

    /// Letter keys next to each other on screen (for typo fixes).
    private var neighbors: Suggester.Neighbors = [:]
    /// The word being typed, kept locally (asking the app for its text on every key is slow).
    private var localWord = ""

    private func updateNeighbors() {
        let letters = caps.dropFirst().flatMap { $0 }.compactMap { c -> (Character, CGRect)? in
            guard case .char(let s) = c.key.kind, let ch = s.first, ch.isLetter else { return nil }
            return (ch, c.frame)
        }
        var m: Suggester.Neighbors = [:]
        for a in letters {
            for b in letters where a.0 != b.0
                && abs(a.1.midX - b.1.midX) <= a.1.width * 1.3 && abs(a.1.midY - b.1.midY) <= a.1.height * 1.5 {
                m[a.0, default: []].insert(b.0)
            }
        }
        neighbors = m
    }

    /// Fingers miss: near the edge of a key the letter that continues a real word wins over the one touched
    /// (a touch can be ~half a key off, the dictionary knows which letter is likely next).
    /// For the word typed so far: how often each next letter continues a word (worked out in the background).
    private var nextTable: (prefix: String, lang: KeyboardLang, base: Int, next: [Character: Int])?
    /// Its own queue (and dictionary reader): not stuck behind the slower suggestion search.
    private let nextQueue = DispatchQueue(label: "next-letter", qos: .userInteractive)

    private func prepareNext() {
        guard !Self.simple, !symbolsMode else { return }
        let lang = self.lang, prefix = Suggester.main.norm(localWord, lang)
        if let t = nextTable, t.prefix == prefix, t.lang == lang { return }
        let letters = caps.dropFirst().flatMap { $0 }.compactMap { c -> Character? in
            if case .char(let s) = c.key.kind, let ch = s.first, ch.isLetter { return ch } else { return nil }
        }
        nextQueue.async { [weak self] in
            let sg = Suggester.next
            var next: [Character: Int] = [:]
            for ch in letters { next[ch] = sg.prefixFreq(prefix + String(ch), lang) }
            let base = prefix.isEmpty ? Int.max : sg.prefixFreq(prefix, lang)
            DispatchQueue.main.async { self?.nextTable = (prefix, lang, base, next) }
        }
    }

    /// Replaces the end of the text: only the part that differs is deleted and typed
    /// (fewer edits for the app to process: "Всера" → "Вчера" keeps the "В").
    private func replaceTail(_ old: String, with new: String) {
        let common = zip(old, new).prefix { $0.0 == $0.1 }.count
        for _ in 0..<(old.count - common) { proxy?.deleteBackward() }
        let rest = String(new.dropFirst(common))
        if !rest.isEmpty { proxy?.insertText(rest) }
    }

    private func likelyKey(at p: CGPoint, nearest: KeyCap) -> KeyCap {
        if Self.simple { return nearest }
        guard !symbolsMode, nearest.row >= 1, case .char(let s0) = nearest.key.kind, s0.first?.isLetter == true else { return nearest }
        let w = nearest.frame.width, h = nearest.frame.height
        let around = caps.dropFirst().flatMap { $0 }.filter { c in
            guard case .char(let s) = c.key.kind, s.first?.isLetter == true else { return false }
            return abs(c.frame.midX - p.x) < w * 1.2 && abs(c.frame.midY - p.y) < h * 1.2
        }
        guard around.count > 1 else { return nearest }
        // the touched key stays unless the finger is near its edge and the touched letter can't continue
        // any common word while the neighbour can (the log showed "вч" → "вс", "хл" → "хо" when it was bolder)
        // the dictionary is never read here: the background has already worked out, for the word typed so far,
        // how often each next letter continues a word (nextTable); not ready yet → the touched key, no waiting
        let prefix = Suggester.main.norm(localWord, lang)
        guard let table = nextTable, table.prefix == prefix, table.lang == lang else { return nearest }
        guard prefix.isEmpty || table.base >= 1000 else { return nearest }
        let ndx = abs(Double((p.x - nearest.frame.midX) / w)), ndy = abs(Double((p.y - nearest.frame.midY) / h))
        guard max(ndx, ndy) > 0.3 else { return nearest }
        func cont(_ c: KeyCap) -> Double {
            guard case .char(let s) = c.key.kind, let ch = s.first else { return 0 }
            return Double(table.next[ch] ?? 0)
        }
        let own = cont(nearest)
        let sigma = 0.4
        var best = nearest, bestScore = -Double.infinity
        for c in around {
            let dx = Double((p.x - c.frame.midX) / w), dy = Double((p.y - c.frame.midY) / h)
            let spatial = -(dx * dx + dy * dy) / (2 * sigma * sigma)
            let f = cont(c)
            if c !== nearest, f < own * 500 { continue }
            let score = spatial + 0.3 * log(f + 1)
            if score > bestScore { bestScore = score; best = c }
        }
        if best !== nearest, case .char(let a) = nearest.key.kind, case .char(let b) = best.key.kind {
            KLog.write("key «\(localWord)» touched \(a) → \(b)")
        }
        return best
    }

    // MARK: touches

    // Every key is its own UIControl and gets its own touches from UIKit (the in-keyboard test with plain system
    // buttons lost nothing, while one big view that handled all touches itself lost many of them).

    private func touch(of cap: KeyCap, _ event: UIEvent?) -> UITouch? { event?.touches(for: cap)?.first }

    @objc private func capDown(_ cap: KeyCap, event: UIEvent?) {
        let t0 = CACurrentMediaTime()
        defer { Speed.add(.down, CACurrentMediaTime() - t0) }
        tick()
        guard let t = touch(of: cap, event) else { KLog.write("↓\(cap.debugName) without its touch — dropped"); return }
        let p = t.location(in: self)
        // iOS re-sends a finger still on the glass as a new touch when another finger lifts (the very same point,
        // up to ~0.25 s later): not a new press — a human never hits the same point twice
        if let last = lastDown, t.timestamp - last.at < 0.25, hypot(p.x - last.p.x, p.y - last.p.y) <= 1 {
            KLog.write("↓ repeat of the same touch ignored")
            lastDown = (p, t.timestamp)
            return
        }
        lastDown = (p, t.timestamp)
        let chosen = likelyKey(at: p, nearest: cap)
        Speed.lastAction = "key \(chosen.debugName)"
        lastOtherDown = t.timestamp
        showTouch(at: p, changed: chosen !== cap)
        KLog.write("↓\(chosen.debugName) late=\(Int((CACurrentMediaTime() - t.timestamp) * 1000))ms fingers=\(tracks.count)")
        // another finger lands: a long press under the first one isn't a long press any more
        for other in tracks.values {
            other.longTimer?.invalidate()
            if let popup = other.popup, !popup.moved { popup.removeFromSuperview(); other.popup = nil }
        }
        let tr = Track(cap: chosen, start: p)
        tr.last = p
        tr.downAt = t.timestamp
        tracks[ObjectIdentifier(cap)] = tr
        chosen.pressed = true
        switch chosen.key.kind {
        case .char:
            type(chosen)
            showPreview(chosen)
            if !chosen.key.alts.isEmpty {
                tr.longTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self, weak tr] _ in
                    guard let self, let tr, self.tracks.values.contains(where: { $0 === tr }) else { return }
                    self.preview.isHidden = true
                    tr.popup = self.showPopup(for: tr.cap)
                }
            }
        case .space:
            space()
            // held still: the space bar becomes a trackpad for the cursor, as in the system keyboard
            tr.longTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak tr] _ in
                guard let self, let tr, self.tracks.values.contains(where: { $0 === tr }),
                      abs(tr.last.x - tr.start.x) < 12, abs(tr.last.y - tr.start.y) < 20 else { return }
                self.startCursorMode(tr)
            }
        case .ret: ret()
        case .backspace:
            deleteBackward()
            tr.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak tr] _ in
                tr?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in self?.deleteBackward() }
            }
        case .shift: tapShift()
        case .globe: if let e = event { controller?.handleInputModeList(from: cap, with: e) }
        default: break
        }
    }

    @objc private func capDrag(_ cap: KeyCap, event: UIEvent?) {
        guard let tr = tracks[ObjectIdentifier(cap)], let t = touch(of: cap, event) else { return }
        let p = t.location(in: self)
        let step = hypot(p.x - tr.last.x, p.y - tr.last.y)
        if step > 1, step < 40 { tr.moves += 1 }
        tr.last = p
        if let popup = tr.popup { popup.select(at: convert(p, to: popup)); return }
        if tr.cursorMode { moveCursor(tr, to: p.x); return }
        if cap.key.kind == .globe, let e = event { controller?.handleInputModeList(from: cap, with: e) }
    }

    @objc private func capUp(_ cap: KeyCap, event: UIEvent?) {
        let t0 = CACurrentMediaTime()
        defer { Speed.add(.up, CACurrentMediaTime() - t0) }
        guard let tr = tracks.removeValue(forKey: ObjectIdentifier(cap)) else { return }
        tr.stop()
        tr.cap.pressed = false
        preview.isHidden = true
        let p = touch(of: cap, event)?.location(in: self) ?? tr.last
        if let popup = tr.popup {
            // the letter typed on touch-down becomes the chosen one ("е" → "ё")
            if let s = popup.selected {
                proxy?.deleteBackward()
                if !localWord.isEmpty { localWord.removeLast() }
                insert(cased(s))
            }
            popup.removeFromSuperview()
            return
        }
        if tr.cursorMode { endCursorMode(); return }
        switch tr.cap.key.kind {
        case .space:
            // a swipe along the space bar switches the language (the space typed on touch-down is taken back)
            // a slide is several small steps of the finger along the bar; a thumb flattening on a quick tap
            // makes one jump (78 pt at once) — a quick swipe must still work, so time is not the test
            if abs(p.x - tr.start.x) > 50, tr.moves >= 3, abs(p.y - tr.start.y) < tr.cap.frame.height, lastOtherDown <= tr.downAt {
                KLog.write("space swipe \(Int(p.x - tr.start.x))pt → language")
                if !undoCorrection() { proxy?.deleteBackward() }
                lastWasSpace = false
                lang = lang.next
            }
        case .symbols: symbolsMode = true; rebuild()
        case .letters: symbolsMode = false; rebuild()
        case .globe: if let e = event { controller?.handleInputModeList(from: cap, with: e) }
        default: break
        }
    }

    @objc private func capCancel(_ cap: KeyCap, event: UIEvent?) {
        guard let tr = tracks.removeValue(forKey: ObjectIdentifier(cap)) else { return }
        KLog.write("touch cancelled on \(tr.cap.debugName)")
        tr.stop()
        tr.cap.pressed = false
        tr.popup?.removeFromSuperview()
        preview.isHidden = true
        if tr.cursorMode { endCursorMode() }
    }

    // MARK: cursor on the space bar

    /// Points of finger travel per character.
    private static let cursorStep: CGFloat = 9

    private func startCursorMode(_ tr: Track) {
        // the space typed on touch-down is taken back (and an autocorrection it made)
        if !undoCorrection() { proxy?.deleteBackward() }
        lastWasSpace = false
        tr.cursorMode = true
        tr.cursorX = tr.last.x
        preview.isHidden = true
        for row in caps { for c in row where c !== tr.cap { c.alpha = 0.35 } }
        tick()
        KLog.write("space held → cursor mode")
    }

    private func moveCursor(_ tr: Track, to x: CGFloat) {
        let steps = Int((x - tr.cursorX) / Self.cursorStep)
        guard steps != 0 else { return }
        tr.cursorX += CGFloat(steps) * Self.cursorStep
        proxy?.adjustTextPosition(byCharacterOffset: steps)
    }

    private func endCursorMode() {
        for row in caps { for c in row { c.alpha = 1 } }
        localWord = ""
        lastCorrection = nil
        cursorMoved = true
        scheduleRefresh()
    }

    /// Each key also answers touches in half the gap to its neighbours and up to the keyboard's edges,
    /// so the gaps and margins still type the nearest key.
    private func updateHitAreas() {
        for (r, row) in caps.enumerated() {
            for (i, cap) in row.enumerated() {
                let f = cap.frame
                let left = i == 0 ? f.minX : (f.minX - row[i - 1].frame.maxX) / 2
                let right = i == row.count - 1 ? bounds.width - f.maxX : (row[i + 1].frame.minX - f.maxX) / 2
                let top = r == 0 ? f.minY - Self.barHeight : (f.minY - caps[r - 1][0].frame.maxY) / 2
                let bottom = r == caps.count - 1 ? bounds.height - f.maxY : (caps[r + 1][0].frame.minY - f.maxY) / 2
                cap.hitOutset = UIEdgeInsets(top: max(0, top), left: max(0, left), bottom: max(0, bottom), right: max(0, right))
            }
        }
    }

    // MARK: actions

    private func cased(_ s: String) -> String { shift != .off && !symbolsMode ? s.uppercased() : s }

    private func type(_ cap: KeyCap) {
        guard case .char(let s) = cap.key.kind else { return }
        insert(cased(s))
    }

    private func insert(_ s: String) {
        lastKeyAt = CACurrentMediaTime()
        revisit = nil
        proxy?.insertText(s)
        if s == "=" { calculate() }
        lastWasSpace = false
        lastCorrection = nil
        prevFix = nil
        if s.count == 1, s.first!.isLetter || s == "'" || s == "-" { localWord += s } else { localWord = "" }
        prepareNext()
        if shift == .once { shift = .off; shiftIsAuto = false; refreshTitles() }
        scheduleRefresh()
    }

    /// "2+2=" → "2+2=4" (the same calculator as on the Mac: chains, %, functions, time).
    private func calculate() {
        guard KLog.defaults.object(forKey: "calculator") as? Bool ?? true else { return }
        let before = proxy?.documentContextBeforeInput ?? ""
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard line.hasSuffix("=") else { return }
        let expr = Calculator.tail(String(line.dropLast()))
        guard let r = Calculator.evaluate(expr) else { return }
        proxy?.insertText(r)
        KLog.write("calc «\(expr)» = \(r)")
    }

    private func ret() {
        // the last word of a line is learned too ("утро всем⏎")
        let before = proxy?.documentContextBeforeInput ?? ""
        if before.last?.isLetter == true { learnLastWord(before) }
        proxy?.insertText("\n")
        localWord = ""
        lastCorrection = nil
        lastWasSpace = false
        scheduleRefresh()
    }

    private var refreshItem: DispatchWorkItem?
    /// The cursor was moved by the user (a tap, arrows), not by typing.
    var cursorMoved = false

    /// Capitals and suggestions need the app's text — a slow request; ask once after a burst of keys, not on every key.
    func scheduleRefresh(after: Double = 0.03) {
        refreshItem?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t0 = CACurrentMediaTime()
            Speed.lastAction = "refresh"
            let ctx = self.proxy?.documentContextBeforeInput ?? ""
            let t1 = CACurrentMediaTime()
            Speed.add(.read, t1 - t0)
            self.localWord = Self.word(ctx)
            self.prepareNext()
            self.autoShift(ctx)
            let t2 = CACurrentMediaTime()
            // the word under the cursor is checked only when the user moved the cursor, not after typing
            let moved = self.cursorMoved
            self.cursorMoved = false
            let revisited = moved && self.checkRevisit(ctx)
            let t3 = CACurrentMediaTime()
            if !revisited { self.updateSuggestions(ctx) }
            let t4 = CACurrentMediaTime()
            if t4 - t0 > 0.05 {
                KLog.write("slow refresh \(Int((t4 - t0) * 1000))ms: read \(Int((t1 - t0) * 1000)) shift \(Int((t2 - t1) * 1000)) revisit \(Int((t3 - t2) * 1000)) suggest \(Int((t4 - t3) * 1000))")
            }
        }
        refreshItem = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }

    private func space() {
        lastKeyAt = CACurrentMediaTime()
        var before = proxy?.documentContextBeforeInput ?? ""
        let typed = Self.word(before)
        if !typed.isEmpty { KLog.write("typed «\(typed)» shown \(lastShown)") }
        // the "↩" button for an earlier word lives for 3 more words (a newer typo replaces it at once)
        if chip != nil, !typed.isEmpty {
            chipAge += 1
            if chipAge > 3 { clearChip() }
        }
        localWord = ""
        prepareNext()
        prevFix = nil
        // a typo with one clear fix is fixed on space (Backspace right after brings the typed word back)
        let ready = precomputed?.word == typed ? precomputed : nil
        // nothing is computed on the key press: if the background hasn't finished this word, space goes in now
        // and the fix (if any) comes on the "previous word" button
        let fix = ready?.fix
        if ready == nil, typed.count >= 3, autocorrectOn, !Self.simple { offerPreviousFix(typed) }
        if autocorrectOn, !Self.simple, !typed.isEmpty, !keepAsTyped.contains(typed.lowercased()), let fix, !People.shared.isName(typed) || fix.lowercased() == typed.lowercased() {
            let shown = Self.matchCase(fix, typed)
            replaceTail(typed, with: shown)
            before = String(before.dropLast(typed.count)) + shown
            lastCorrection = (typed, shown)
            lastWasSpace = false
            KLog.write("autocorrect «\(typed)» → «\(shown)»")
        } else if let r = ready, !r.fixes.isEmpty {
            // not sure which fix: keep offering them for the word just finished
            prevFix = (typed, r.fixes.map { Self.matchCase($0, typed) })
            setChip(typed, Self.matchCase(r.fixes[0], typed))
        }
        learnLastWord(before)
        let after: String
        // double space → ". " after a word
        if lastWasSpace, before.hasSuffix(" "), let c = before.dropLast().last, c.isLetter || c.isNumber {
            proxy?.deleteBackward()
            proxy?.insertText(". ")
            after = before.dropLast() + ". "
            lastWasSpace = false
        } else {
            proxy?.insertText(" ")
            after = before + " "
            lastWasSpace = true
        }
        if symbolsMode { symbolsMode = false; rebuild() }
        autoShift(after)          // right away: the next letter may already be coming
        if let pf = prevFix { bar.show(pf.fixes, typed: ""); lastShown = pf.fixes; latest.bump() } else { scheduleRefresh() }
    }

    private var lastCorrection: (typed: String, fixed: String)?

    // MARK: previous-word button

    /// A finished word with a typo: "↩ fix" stays in the bar while you type on; a tap fixes that word in place.
    private var chip: (word: String, fix: String)?
    /// Words typed since the button appeared: after a few it is old news and goes away.
    private var chipAge = 0

    private func setChip(_ word: String, _ fix: String) {
        chip = (word, fix)
        chipAge = 0
        bar.chip = "↩ " + fix
        KLog.write("previous-word button «\(word)» → «\(fix)»")
    }

    private func clearChip() { chip = nil; bar.chip = nil }

    /// Worked out in the background for a word finished before its fix was ready.
    private func offerPreviousFix(_ typed: String) {
        let lang = self.lang, near = self.neighbors
        work.async { [weak self] in
            let sg = Suggester.shared
            let ff = sg.fixes(sg.norm(typed, lang), lang: lang, near: near, final: true, deep: true)
            guard let best = ff.first(where: { $0.p >= 0.25 || $0.w.contains(" ") })?.w else { return }
            DispatchQueue.main.async { self?.setChip(typed, Self.matchCase(best, typed)) }
        }
    }

    /// Replaces the word somewhere before the cursor and puts the cursor back where it was.
    /// Learns the word just finished after the ones before it — only a real word, a contact name or a word the
    /// user kept: a typo ("галости") is not a habit.
    private func learnLastWord(_ before: String) {
        let ws = NGrams.sentenceWords(before)
        guard let w = ws.last, knownWord(w) else { return }
        NGrams.shared.learn(ws)
    }

    private func knownWord(_ w: String) -> Bool {
        let l = w.lowercased()
        if keepAsTyped.contains(l) || People.shared.isName(l) { return true }
        let lang: KeyboardLang = l.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } ? .ru : .en
        let s = Suggester.main, k = s.norm(l, lang)
        return s.isReal(k, lang) || s.isName(k, lang)
    }

    private func applyChip() {
        guard let c = chip else { return }
        clearChip()
        let before = proxy?.documentContextBeforeInput ?? ""
        guard let r = before.range(of: c.word, options: .backwards) else { KLog.write("previous word «\(c.word)» not found"); return }
        let after = before[r.upperBound...].count
        proxy?.adjustTextPosition(byCharacterOffset: -after)
        for _ in c.word { proxy?.deleteBackward() }
        proxy?.insertText(c.fix)
        proxy?.adjustTextPosition(byCharacterOffset: after)
        KLog.write("previous word fixed «\(c.word)» → «\(c.fix)» (\(after) chars back)")
        scheduleRefresh()
    }
    /// Worked out in the background while the word was typed: what space would fix it to.
    private var precomputed: (word: String, fix: String?, fixes: [String])?
    private var prevFix: (typed: String, fixes: [String])?
    /// Words the user took back after a fix ("веб", "Ене"): never fixed again — kept across launches.
    private var keepAsTyped = Set(KLog.defaults.stringArray(forKey: "keepAsTyped") ?? []) {
        didSet { KLog.defaults.set(Array(keepAsTyped.suffix(2000)), forKey: "keepAsTyped") }
    }
    private var autocorrectOn: Bool { KLog.defaults.object(forKey: "autocorrect") as? Bool ?? true }

    static func matchCase(_ w: String, _ typed: String) -> String {
        if typed.count > 1, typed == typed.uppercased() { return w.uppercased() }
        if typed.first?.isUppercase == true { return w.prefix(1).uppercased() + w.dropFirst() }
        return w
    }

    /// Backspace right after an autocorrection: the typed word comes back.
    private func undoCorrection() -> Bool {
        guard let c = lastCorrection else { return false }
        lastCorrection = nil
        let before = proxy?.documentContextBeforeInput ?? ""
        guard before.hasSuffix(c.fixed + " ") else { return false }
        for _ in 0..<(c.fixed.count + 1) { proxy?.deleteBackward() }
        proxy?.insertText(c.typed)
        keepAsTyped.insert(c.typed.lowercased())
        localWord = c.typed
        KLog.write("autocorrect undone «\(c.fixed)» → «\(c.typed)»")
        scheduleRefresh()
        return true
    }

    private func deleteBackward() {
        lastKeyAt = CACurrentMediaTime()
        if undoCorrection() { return }
        prevFix = nil
        proxy?.deleteBackward()
        if !localWord.isEmpty { localWord.removeLast() }
        prepareNext()
        lastWasSpace = false
        scheduleRefresh()
    }

    private func tapShift() {
        let now = Date()
        switch shift {
        case .off: shift = .once
        case .once: shift = now.timeIntervalSince(lastShiftTap) < 0.35 && !shiftIsAuto ? .locked : .off
        case .locked: shift = .off
        }
        shiftIsAuto = false
        lastShiftTap = now
        refreshTitles()
    }

    /// Capital letter at the start of a sentence (if the field wants it).
    func autoShift(_ ctx: String? = nil) {
        guard shift != .locked else { return }
        let wants: Bool = {
            guard let p = proxy, p.autocapitalizationType != UITextAutocapitalizationType.none else { return false }
            let before = ctx ?? p.documentContextBeforeInput ?? ""
            let t = before.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || before.hasSuffix("\n") { return true }
            return before.hasSuffix(" ") && [".", "!", "?", "…"].contains(t.last.map(String.init) ?? "")
        }()
        if wants, shift == .off { shift = .once; shiftIsAuto = true; refreshTitles() }
        else if !wants, shift == .once, shiftIsAuto { shift = .off; shiftIsAuto = false; refreshTitles() }
    }

    // MARK: vibration & settings

    private var hapticsOn: Bool { KLog.defaults.object(forKey: "haptics") as? Bool ?? true }

    /// A light tap of the vibration motor on every key (iOS allows it only with Full Access).
    private func tick() {
        // the very first thing on a touch: feeling the key late feels like a slow keyboard
        guard hapticsOn, controller?.hasFullAccess == true else { return }
        Haptics.shared.tap(strength: KLog.defaults.object(forKey: "hapticStrength2") as? Int ?? 0)
    }

    private var panel: SettingsPanel?

    private func openSettings() {
        guard panel == nil else { return }
        let p = SettingsPanel(fullAccess: controller?.hasFullAccess == true)
        p.onClose = { [weak self] in self?.panel?.removeFromSuperview(); self?.panel = nil; self?.updateSuggestions() }
        p.onButtonTest = { [weak self] in
            guard let self else { return }
            self.panel?.removeFromSuperview(); self.panel = nil
            let t = ButtonTestView(proxy: self.proxy)
            t.frame = self.bounds
            t.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.addSubview(t)
        }
        p.onTapTest = { [weak self] in
            guard let self else { return }
            self.panel?.removeFromSuperview(); self.panel = nil
            let t = TapTestView(proxy: self.proxy)
            t.frame = self.bounds
            t.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.addSubview(t)
        }
        p.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        p.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(p)
        panel = p
    }

    // MARK: touch dots

    private var showTouchesOn: Bool { KLog.defaults.object(forKey: "showTouches") as? Bool ?? false }

    /// A dot where the finger landed, fading in 1.5 s: no dot = iOS never gave the keyboard this touch.
    /// Blue — the touched key, orange — a neighbouring key was chosen by the dictionary.
    private func showTouch(at p: CGPoint, changed: Bool) {
        guard showTouchesOn else { return }
        let d: CGFloat = 22
        let dot = CALayer()
        dot.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        dot.cornerRadius = d / 2
        dot.backgroundColor = (changed ? UIColor.systemOrange : UIColor.systemBlue).withAlphaComponent(0.55).cgColor
        layer.addSublayer(dot)
        CATransaction.begin()
        CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 1.5
        dot.opacity = 0
        dot.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: suggestions

    /// The word being typed: letters right before the cursor.
    private func currentWord() -> String { Self.word(proxy?.documentContextBeforeInput ?? "") }

    static func word(_ before: String) -> String {
        String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }.reversed())
    }

    private var lastShown: [String] = []
    private var gender: Gender { Gender(rawValue: KLog.defaults.string(forKey: "gender") ?? "") ?? .none }

    private let work = DispatchQueue(label: "suggest", qos: .userInitiated)
    private let latest = Latest()

    /// Suggestions are computed off the main thread so typing never waits for them; only the newest result is shown.
    /// Test mode: plain typing only (no suggestions, fixes or key guessing) — to see whether missed touches remain.
    static var simple: Bool { KLog.defaults.bool(forKey: "simple") }

    func updateSuggestions(_ context: String? = nil) {
        if Self.simple { bar.show([], typed: ""); lastShown = []; return }
        let ctx = context ?? proxy?.documentContextBeforeInput ?? ""
        let word = Self.word(ctx)
        // phrases from Apple's model: off — asking the system whether the model is ready froze the keyboard
        // for 0.45–0.85 s after every space (the log: "MAIN STALL … after refresh"), and the model is unavailable here
        if word.isEmpty, let pf = prevFix, ctx.hasSuffix(pf.typed + " ") { bar.show(pf.fixes, typed: ""); lastShown = pf.fixes; return }
        // after a space: the next word (and a short phrase) the user usually writes here
        if word.isEmpty, !symbolsMode, !Self.simple, ctx.last == " " {
            let words = NGrams.sentenceWords(ctx)
            var next = NGrams.shared.predict(after: words, limit: 6).filter { knownWord($0) }.prefix(3).map { w in
                People.shared.names.first { $0.lowercased() == w } ?? w }.map { Self.matchCase($0, ctx.trimmingCharacters(in: .whitespaces).last.map { ".!?".contains($0) } == true ? "A" : "a") }
            if let ph = NGrams.shared.phrase(after: words), let first = next.first, ph.hasPrefix(first.lowercased() + " "),
               ph.split(separator: " ").allSatisfy({ knownWord(String($0)) }) {
                next[0] = Self.matchCase(ph, next[0])
            }
            if !next.isEmpty {
                latest.bump()
                bar.show(next, typed: "")
                lastShown = next
                KLog.write("next after «\(words.suffix(2).joined(separator: " "))» → \(next)")
                return
            }
        }
        // e-mails: "vit@" → the contact's address; in an e-mail field — any beginning
        let token = String(ctx.reversed().prefix { !$0.isWhitespace }.reversed())
        let emailField = proxy?.keyboardType == .emailAddress || proxy?.textContentType == .emailAddress || proxy?.textContentType == .username
        if let e = People.shared.emails(for: token, emailField: emailField).first {
            emailToken = token
            bar.showWide(e)
            lastShown = [e]
            latest.bump()
            return
        }
        emailToken = nil
        let nameHits = People.shared.names(startingWith: word), allNames = People.shared.names
        guard word.count >= 1, !symbolsMode else { bar.show([], typed: ""); lastShown = []; latest.bump(); return }
        let before = String(ctx.dropLast(word.count))
        let lang = self.lang, gender = self.gender, near = self.neighbors
        let id = latest.bump()
        work.async { [weak self] in
            guard let self, self.latest.is(id) else { return }      // a newer key already came
            let t0 = Date()
            var out = Suggester.shared.suggest(word: word, before: before, lang: lang, gender: gender, near: near)
            let sg = Suggester.shared
            let key = sg.norm(word, lang)
            let wordIsReal = sg.isReal(key, lang)
            // contact names: a beginning ("Вит" → "Виталий") or a slip ("Виталй"); typed with a capital or not a
            // real word → first, else second
            let exactName = allNames.first { $0.lowercased() == word.lowercased() }
            let nameSlips = word.count >= 3 && !wordIsReal && exactName == nil ? People.slips(word, in: allNames) : []
            if let n = (nameSlips + nameHits).first(where: { n in !out.contains { $0.lowercased() == n.lowercased() } }) {
                out.insert(n, at: word.first?.isUppercase == true || !wordIsReal ? 0 : min(1, out.count))
                out = Array(out.prefix(3))
                KLog.write("name for «\(word)» → \(n)")
            }
            // what space would do with this word: worked out here, never on the key press itself
            let finalFixes = sg.fixes(key, lang: lang, near: near, final: true, deep: true)
            var fix = sg.autocorrect(word, lang: lang, near: near, finalFixes: finalFixes)
            // the "↩" button only for a likely slip (not "кей" → "ей": dropping the first letter)
            var fixes = Array(finalFixes.filter { $0.p >= 0.25 || $0.w.contains(" ") }.prefix(3).map(\.w))
            // a contact name that isn't a dictionary word: written as in the contacts ("даша" → "Даша"), and
            // a slip with only one such name nearby is fixed to it
            if fix == nil, word.count >= 3, !wordIsReal {
                if let e = exactName, e != word, word != word.uppercased() { fix = e }
                else if nameSlips.count == 1, fixes.isEmpty { fix = nameSlips[0] }
            }
            if fixes.isEmpty { fixes = Array(nameSlips.prefix(3)) }
            if word.first?.isUppercase == true {
                out = out.map { $0.first?.isUppercase == true ? $0 : word == word.uppercased() && word.count > 1 ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async {
                guard self.latest.is(id) else { return }
                let prev = NGrams.sentenceWords(before)
                let habit = out.map { NGrams.shared.count(of: $0.lowercased(), after: prev) }
                if habit.contains(where: { $0 > 0 }) {
                    out = zip(out, habit).enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map { $0.element.0 }
                }
                self.precomputed = (word, fix, Array(fixes))
                self.lastShown = out
                self.bar.show(out, typed: word)
                KLog.write("suggest «\(word)» → \(out) \(ms)ms")
            }
        }
    }

    /// Phrase row: the next words after a finished word (Apple's on-device model, if available).
    private func updatePhrase(_ ctx: String, word: String) {
        guard word.isEmpty, !symbolsMode, let last = ctx.last, last == " ", ctx.contains(where: { $0.isLetter }) else {
            Phrase.shared.cancel()
            if word.isEmpty || !bar.phraseText.lowercased().hasPrefix(word.lowercased()) { bar.showPhrase(nil) }
            return
        }
        bar.showPhrase(nil)
        Phrase.shared.request(ctx) { [weak self] p in self?.bar.showPhrase(p) }
    }

    private func pickPhrase(_ p: String) {
        KLog.write("pick phrase «\(p)»")
        let word = currentWord()
        // the phrase may start with the word being typed
        if !word.isEmpty, p.lowercased().hasPrefix(word.lowercased()) { for _ in word { proxy?.deleteBackward() } }
        proxy?.insertText(p + " ")
        lastWasSpace = true
        autoShift()
        updateSuggestions()
    }

    private var emailToken: String?
    private var lastKeyAt: CFTimeInterval = 0
    private var revisit: (before: String, after: String, fixes: [String])?

    /// The cursor was put into or after a word (a tap, arrows) — not typing: if the word is misspelled,
    /// offer its fixes; picking one replaces the whole word (the same idea as the typo check on the Mac).
    private func checkRevisit(_ ctx: String) -> Bool {
        revisit = nil
        guard CACurrentMediaTime() - lastKeyAt > 0.4 else { return false }
        let after = proxy?.documentContextAfterInput ?? ""
        let isW: (Character) -> Bool = { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
        let b = Self.word(ctx), a = String(after.prefix(while: isW))
        let whole = b + a
        guard whole.count >= 3, !People.shared.isName(whole) else { return false }
        let wl: KeyboardLang = whole.unicodeScalars.contains { $0.isASCII } ? .en : .ru
        let main = Suggester.main
        let key = main.norm(whole, wl)
        guard main.freq(key, wl) == 0 else { return false }
        // the search itself runs in the background: the keyboard must stay responsive after a pause
        let near = wl == lang ? neighbors : [:]
        let id = latest.bump()
        work.async { [weak self] in
            let fx = Suggester.shared.fixes(key, lang: wl, near: near, final: true, deep: true).prefix(3).map { Self.matchCase($0.w, whole) }
            DispatchQueue.main.async {
                guard let self, self.latest.is(id), !fx.isEmpty else { return }
                self.revisit = (b, a, Array(fx))
                self.bar.show(Array(fx), typed: "")
                self.lastShown = Array(fx)
                KLog.write("revisit «\(whole)» → \(fx)")
            }
        }
        return true
    }

    private func pick(_ s: String) {
        lastKeyAt = CACurrentMediaTime()
        if let r = revisit {
            // the whole word around the cursor is replaced
            revisit = nil
            proxy?.adjustTextPosition(byCharacterOffset: r.after.count)
            for _ in 0..<(r.before.count + r.after.count) { proxy?.deleteBackward() }
            proxy?.insertText(s)
            localWord = ""
            KLog.write("revisit fixed «\(r.before + r.after)» → «\(s)»")
            scheduleRefresh()
            return
        }
        if let t = emailToken {
            for _ in t { proxy?.deleteBackward() }
            proxy?.insertText(s + (proxy?.keyboardType == .emailAddress ? "" : " "))
            emailToken = nil
            localWord = ""
            KLog.write("pick e-mail for «\(t)»")
            scheduleRefresh()
            return
        }
        let slot = lastShown.firstIndex(of: s).map { $0 + 1 } ?? 0
        KLog.write("pick «\(currentWord())» → «\(s)» (#\(slot) of \(lastShown))")
        if let pf = prevFix, (proxy?.documentContextBeforeInput ?? "").hasSuffix(pf.typed + " ") {
            for _ in 0..<(pf.typed.count + 1) { proxy?.deleteBackward() }
            prevFix = nil
            KLog.write("fixed previous «\(pf.typed)» → «\(s)»")
        } else {
            for _ in currentWord() { proxy?.deleteBackward() }
        }
        localWord = ""
        proxy?.insertText(s + " ")
        let ctxNow = (proxy?.documentContextBeforeInput ?? "")
        let ws = NGrams.sentenceWords(ctxNow)
        for i in max(1, ws.count - s.split(separator: " ").count + 1)...max(1, ws.count) { NGrams.shared.learn(Array(ws.prefix(i))) }
        lastWasSpace = true
        if shift == .once { shift = .off; shiftIsAuto = false; refreshTitles() }
        autoShift()
        updateSuggestions()
    }

    // MARK: balloons

    private func showPreview(_ cap: KeyCap) {
        guard KeyboardView.animations, case .char(let s) = cap.key.kind else { preview.isHidden = true; return }
        if preview.superview == nil { addSubview(preview) }
        bringSubviewToFront(preview)
        let w = cap.frame.width + 16, h = cap.frame.height * 1.15
        preview.frame = CGRect(x: min(max(0, cap.frame.midX - w / 2), bounds.width - w), y: max(0, cap.frame.minY - h - 4), width: w, height: min(h, cap.frame.minY - 2))
        preview.label.text = cased(s)
        preview.isHidden = false
    }

    private func showPopup(for cap: KeyCap) -> AltPopup {
        // the first choice sits right above the finger: on the right half of the keyboard the strip runs leftwards
        // ("." → "?" at the right end, where the thumb is)
        let rightSide = cap.frame.midX > bounds.midX
        let alts = cap.key.alts.map(cased)
        let popup = AltPopup(items: rightSide ? alts.reversed() : alts, initial: rightSide ? alts.count - 1 : 0)
        let cellW = max(cap.frame.width, 34), h = cap.frame.height * 1.1
        let w = cellW * CGFloat(popup.items.count)
        // always above the finger (it covers the key and a bit above); the top row uses the suggestion bar
        let lift = cap.frame.height * 0.6
        let ph = min(h, cap.frame.minY - 4)
        let y = max(0, cap.frame.minY - lift - ph)
        let x = alts.count == 1 ? cap.frame.midX - w / 2 : (rightSide ? cap.frame.maxX - w : cap.frame.minX)
        popup.frame = CGRect(x: min(max(2, x), bounds.width - 2 - w), y: y, width: w, height: ph)
        addSubview(popup)
        return popup
    }
}

final class PreviewBalloon: UIView {
    let label = UILabel()
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = KeyboardView.keyColor
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
}

/// Long-press choices (ё, щ, ъ, э…); the finger slides to pick one.
final class AltPopup: UIView {
    let items: [String]
    private var labels: [UILabel] = []
    private(set) var selected: String?
    private(set) var moved = false

    init(items: [String], initial: Int = 0) {
        self.items = items
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = KeyboardView.keyColor
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 4
        for s in items {
            let l = UILabel()
            l.text = s
            l.font = .systemFont(ofSize: 24)
            l.textAlignment = .center
            l.layer.cornerRadius = 8
            l.clipsToBounds = true
            addSubview(l)
            labels.append(l)
        }
        highlight(initial)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width / CGFloat(max(1, labels.count))
        for (i, l) in labels.enumerated() { l.frame = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height).insetBy(dx: 2, dy: 3) }
    }

    func select(at p: CGPoint) {
        moved = true
        let w = bounds.width / CGFloat(max(1, labels.count))
        highlight(min(labels.count - 1, max(0, Int(p.x / w))))
    }

    private func highlight(_ i: Int) {
        for (j, l) in labels.enumerated() {
            l.backgroundColor = j == i ? .systemBlue : .clear
            l.textColor = j == i ? .white : .label
        }
        selected = items.indices.contains(i) ? items[i] : nil
    }
}

/// Word suggestions above the keys: the best one in the middle, tap to insert.
final class SuggestionBar: UIView {
    static let bold = UIFont.systemFont(ofSize: 17, weight: .semibold)
    static let regular = UIFont.systemFont(ofSize: 17)
    var onPick: ((String) -> Void)?
    var onChip: (() -> Void)?
    /// "↩ fix" for the previous word, shown in the left slot.
    var chip: String? { didSet { show(lastItems, typed: "") } }
    private var lastItems: [String] = []
    var onSettings: (() -> Void)?
    var onPhrase: ((String) -> Void)?
    private let phrase = UIButton(type: .system)
    private let gear = UIButton(type: .system)
    private var buttons: [UIButton] = []
    private var dividers: [UIView] = []

    init() {
        super.init(frame: .zero)
        for _ in 0..<3 {
            let b = UIButton(type: .system)
            b.titleLabel?.font = .systemFont(ofSize: 17)
            b.titleLabel?.lineBreakMode = .byTruncatingTail
            b.setTitleColor(.label, for: .normal)
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let self, let b, let t = b.title(for: .normal), !t.isEmpty else { return }
                if b === self.buttons.first, self.chip != nil, t == self.chip { self.onChip?() } else { self.onPick?(t) }
            }, for: .touchUpInside)
            addSubview(b)
            buttons.append(b)
        }
        phrase.titleLabel?.font = .systemFont(ofSize: 16)
        phrase.titleLabel?.lineBreakMode = .byTruncatingTail
        phrase.setTitleColor(.secondaryLabel, for: .normal)
        phrase.contentHorizontalAlignment = .center
        phrase.addAction(UIAction { [weak self] _ in
            if let t = self?.phraseText, !t.isEmpty { self?.onPhrase?(t) }
        }, for: .touchUpInside)
        addSubview(phrase)
        gear.setImage(UIImage(systemName: "gearshape"), for: .normal)
        gear.tintColor = .secondaryLabel
        gear.addAction(UIAction { [weak self] _ in self?.onSettings?() }, for: .touchUpInside)
        addSubview(gear)
        for _ in 0..<2 {
            let d = UIView()
            d.backgroundColor = .separator
            addSubview(d)
            dividers.append(d)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let g: CGFloat = 40, ph: CGFloat = 0
        phrase.frame = CGRect(x: g, y: 0, width: bounds.width - 2 * g, height: ph)
        let y = ph, h = bounds.height - ph
        gear.frame = CGRect(x: 0, y: y, width: g, height: h)
        let w = (bounds.width - 2 * g) / 3
        for (i, b) in buttons.enumerated() { b.frame = CGRect(x: g + CGFloat(i) * w, y: y, width: w, height: h).insetBy(dx: 4, dy: 0) }
        for (i, d) in dividers.enumerated() { d.frame = CGRect(x: g + CGFloat(i + 1) * w, y: y + 10, width: 1, height: h - 20) }
        if wide { buttons[1].frame = CGRect(x: g, y: y, width: bounds.width - 2 * g, height: h) }
    }

    private(set) var phraseText = ""

    func showPhrase(_ s: String?) {
        phraseText = s ?? ""
        phrase.setTitle(phraseText.isEmpty ? "" : "\(phraseText) →", for: .normal)
    }

    /// One long item (an e-mail) across the whole row.
    func showWide(_ s: String) {
        show([s], typed: "")
        wide = true
        setNeedsLayout()
    }
    private var wide = false

    /// Order on screen: second, best, third.
    func show(_ items: [String], typed: String) {
        if wide { wide = false; setNeedsLayout() }
        lastItems = items
        let slots = [1, 0, 2]
        for (pos, b) in buttons.enumerated() {
            let i = slots[pos]
            var t = items.indices.contains(i) ? items[i] : ""
            if pos == 0, let c = chip { t = c }
            let color: UIColor = pos == 0 && chip != nil ? .systemOrange : .label
            if b.titleColor(for: .normal) != color { b.setTitleColor(color, for: .normal) }
            if b.title(for: .normal) ?? "" != t { b.setTitle(t, for: .normal) }
            let f = i == 0 ? Self.bold : Self.regular
            if b.titleLabel?.font != f { b.titleLabel?.font = f }
        }
        dividers.forEach { $0.isHidden = items.count < 2 }
    }
}

/// Settings inside the keyboard: how to speak about me, vibration, debug log.
final class SettingsPanel: UIView {
    var onClose: (() -> Void)?
    var onTapTest: (() -> Void)?
    var onButtonTest: (() -> Void)?

    init(fullAccess: Bool) {
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground
        let d = KLog.defaults

        let gTitle = label("Подсказки о себе")
        let seg = UISegmentedControl(items: ["пошёл", "пошла", "не учитывать"])
        let order: [Gender] = [.masculine, .feminine, .none]
        seg.selectedSegmentIndex = order.firstIndex(of: Gender(rawValue: d.string(forKey: "gender") ?? "") ?? .none) ?? 2
        seg.addAction(UIAction { _ in d.set(order[seg.selectedSegmentIndex].rawValue, forKey: "gender") }, for: .valueChanged)

        let vib = row("Вибрация при нажатии", on: d.object(forKey: "haptics") as? Bool ?? true) { d.set($0, forKey: "haptics") }
        let note = label(fullAccess ? "" : "Для вибрации: Настройки → Основные → Клавиатура → Клавиатуры → ExoKey → Полный доступ")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabel
        note.numberOfLines = 2
        let log = row("Журнал для отладки", on: KLog.enabled) { d.set($0, forKey: "log") }
        let auto = row("Исправлять опечатки на пробел", on: d.object(forKey: "autocorrect") as? Bool ?? true) { d.set($0, forKey: "autocorrect") }
        let simple = row("Простой режим (тест)", on: d.bool(forKey: "simple")) { d.set($0, forKey: "simple") }
        let people = row("Имена и e-mail из контактов", on: d.object(forKey: "contacts") as? Bool ?? true) { d.set($0, forKey: "contacts") }
        let calc = row("Калькулятор (2+2=)", on: d.object(forKey: "calculator") as? Bool ?? true) { d.set($0, forKey: "calculator") }
        let prev = row("Анимации (буква над пальцем, подсветка)", on: KeyboardView.animations) { d.set($0, forKey: "animations") }
        let dots = row("Показывать касания", on: d.object(forKey: "showTouches") as? Bool ?? false) { d.set($0, forKey: "showTouches") }
        let strength = UISegmentedControl(items: ["слабая", "средняя", "сильная"])
        strength.selectedSegmentIndex = d.object(forKey: "hapticStrength2") as? Int ?? 0
        strength.addAction(UIAction { _ in d.set(strength.selectedSegmentIndex, forKey: "hapticStrength2") }, for: .valueChanged)
        let btnTest = UIButton(type: .system)
        btnTest.setTitle("Тест: системные кнопки вместо наших клавиш", for: .normal)
        btnTest.contentHorizontalAlignment = .leading
        btnTest.addAction(UIAction { [weak self] _ in self?.onButtonTest?() }, for: .touchUpInside)
        let test = UIButton(type: .system)
        test.setTitle("Тест касаний (пустое поле со счётчиком)", for: .normal)
        test.contentHorizontalAlignment = .leading
        test.addAction(UIAction { [weak self] _ in self?.onTapTest?() }, for: .touchUpInside)

        let done = UIButton(type: .system)
        done.setTitle("Готово", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [gTitle, seg, auto, people, calc, vib, strength, note, prev, simple, btnTest, dots, test, log, done])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        // more settings than fit in the keyboard's height: scroll
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String) -> UILabel {
        let l = UILabel()
        l.text = s
        l.font = .systemFont(ofSize: 15)
        return l
    }

    private func row(_ title: String, on: Bool, _ changed: @escaping (Bool) -> Void) -> UIView {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { _ in changed(sw.isOn) }, for: .valueChanged)
        let h = UIStackView(arrangedSubviews: [label(title), sw])
        h.axis = .horizontal
        return h
    }
}

/// The id of the newest suggestion request (read from the worker thread).
final class Latest {
    private var n = 0
    private let lock = NSLock()
    @discardableResult func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    func `is`(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return n == id }
}

/// The bare minimum: one plain area that counts touches (no keys, no drawing, nothing else).
/// Tap it N times: if the count is lower, iOS did not give the keyboard those touches.
final class TapTestView: UIView {
    private let count = UILabel()
    private let hint = UILabel()
    private let insert = UISwitch()
    private var n = 0
    private weak var proxy: UITextDocumentProxy?

    init(proxy: UITextDocumentProxy?) {
        self.proxy = proxy
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .systemBackground
        count.font = .monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        count.textAlignment = .center
        count.text = "0"
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.text = "Нажимайте в любое место и считайте. Переключатель справа: вставлять «о» в текст. Выход — нажать и держать 1 с."
        [count, hint, insert].forEach { addSubview($0) }
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(close(_:)))
        hold.minimumPressDuration = 1
        hold.cancelsTouchesInView = false
        addGestureRecognizer(hold)
        KLog.write("taptest: start")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        count.frame = CGRect(x: 0, y: bounds.height * 0.25, width: bounds.width, height: 70)
        hint.frame = CGRect(x: 20, y: count.frame.maxY + 6, width: bounds.width - 40, height: 50)
        insert.sizeToFit()
        insert.frame.origin = CGPoint(x: bounds.width - insert.frame.width - 16, y: 12)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where !insert.frame.insetBy(dx: -10, dy: -10).contains(t.location(in: self)) {
            n += 1
            if insert.isOn { proxy?.insertText("о") }
            KLog.write("taptest \(n) late=\(Int((CACurrentMediaTime() - t.timestamp) * 1000))ms all=\(event?.allTouches?.count ?? 0)")
        }
        count.text = "\(n)"
    }

    @objc private func close(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        KLog.write("taptest: end n=\(n) insert=\(insert.isOn)")
        removeFromSuperview()
    }
}

/// The test with plain system buttons (a letter on touch-down, nothing else): if letters are lost here too,
/// iOS drops the touches, not ExoKey's own touch handling. "выход" goes back to the normal keys.
final class ButtonTestView: UIView {
    private weak var proxy: UITextDocumentProxy?
    var onExit: (() -> Void)?

    init(proxy: UITextDocumentProxy?) {
        self.proxy = proxy
        super.init(frame: .zero)
        backgroundColor = .systemGray5
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        for r in ["1234567890", "йцукенгшщзх", "фывапролджэ", "ячсмитьбю⌫"] { stack.addArrangedSubview(row(r.map { String($0) })) }
        stack.addArrangedSubview(row(["выход", " ", ".", "⏎"]))
        KLog.write("button test: start")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func row(_ keys: [String]) -> UIStackView {
        let h = UIStackView()
        h.axis = .horizontal
        h.spacing = 6
        h.distribution = .fill
        var first: UIButton?
        for k in keys {
            let b = UIButton(type: .system)
            b.setTitle(k == " " ? "пробел" : k, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: k.count > 1 ? 15 : 22)
            b.setTitleColor(.label, for: .normal)
            b.backgroundColor = .systemBackground
            b.layer.cornerRadius = 6
            b.addAction(UIAction { [weak self] _ in self?.press(k) }, for: .touchDown)
            h.addArrangedSubview(b)
            if k == " " { b.widthAnchor.constraint(equalTo: h.widthAnchor, multiplier: 0.5).isActive = true }
            else if k.count == 1, let f = first { b.widthAnchor.constraint(equalTo: f.widthAnchor).isActive = true }
            else if first == nil, k.count == 1 { first = b }
        }
        if keys.count > 6 { h.distribution = .fillEqually }
        return h
    }

    // a touch between the buttons must not reach the real keys underneath
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { KLog.write("btn gap") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}

    private func press(_ k: String) {
        switch k {
        case "⌫": proxy?.deleteBackward()
        case "⏎": proxy?.insertText("\n")
        case "выход": KLog.write("button test: end"); onExit?(); removeFromSuperview()
        default: proxy?.insertText(k)
        }
        KLog.write("btn \(k == " " ? "␣" : k)")
    }
}
