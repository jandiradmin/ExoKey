import AppKit

final class SpellFix {
    static let shared = SpellFix()
    private var indexes: [Lang: SpellIndex] = [:]
    private let queue = DispatchQueue(label: "exokey.spell", qos: .userInitiated)
    private var loading = false

    // offer (plaque) state
    private(set) var offer: (orig: String, fix: String, boundary: String)?
    private var generation = 0
    /// Letters typed after the finished word (the next word in progress); nil = tracking stopped
    private var typedAfter: String?
    private var autoHide: DispatchWorkItem?
    // last applied fix, for ⌃⌥Z
    private var applied: (orig: String, fix: String, boundary: String)?
    private var keysSinceApply = 0

    private let panel: NSPanel
    private let label: NSTextField
    private let bg: NSVisualEffectView

    var isOffering: Bool { offer != nil && panel.isVisible }

    private init() {
        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.95, alpha: 1)
        bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let root = NSView()
        root.addSubview(bg)
        root.addSubview(label)
        panel.contentView = root
    }

    /// Builds indexes in the background (first use or app start).
    func warmUp() {
        guard !loading, Settings.shared.spellMode > 0 else { return }
        loading = true
        let dicts = Engine.shared.dicts
        queue.async {
            for l in Lang.allCases {
                guard let d = dicts[l] else { continue }
                let ix = SpellIndex(lang: l)
                ix.build(d)
                DispatchQueue.main.async { self.indexes[l] = ix }
            }
        }
    }

    // MARK: decision

    /// Correction for a finished word as typed (with case), or nil. Runs on the spell queue.
    private func correction(_ typed: String, _ lang: Lang, auto: Bool) -> String? {
        guard let ix = indexes[lang], ix.ready else { return nil }
        let lower = TextNorm.normalize(typed, lang)
        guard lower.count >= 3, lower.allSatisfy({ TextNorm.isLetter($0, lang) || $0 == "-" || $0 == "'" }) else { return nil }
        if UserStore.shared.isWord(lower, lang) || UserStore.shared.isException(lower, lang) { return nil }
        let wf = Engine.shared.dicts[lang]?.freq(lower) ?? 0
        // a real word stays; a frequency-list word unknown to Hunspell may be a typo
        if wf > 0 && (!ix.isUnverified(lower) || wf >= 2000) { return nil }
        guard let (d, cand, cf) = ix.best(for: lower) else { return nil }
        if wf > 0 && cf < wf * (auto ? 3000 : 100) { return nil }
        if auto && (d > 2 || cf < 1000) { return nil }
        if d >= 3 && cf < 50 { return nil }
        // keep the case the user typed
        var out = cand
        if typed == typed.uppercased() && typed.count > 1 { out = cand.uppercased() }
        else if typed.first?.isUppercase == true || NameCase.shared.isName(cand, lang) { out = NameCase.capitalize(cand) }
        return out == typed ? nil : out
    }

    // MARK: entry points from Engine

    /// Word finished with a space or punctuation. Mode 1: offer a plaque; mode 2: replace right away.
    func wordFinished(_ typed: String, lang: Lang, boundary: String) {
        let mode = Settings.shared.spellMode
        guard mode > 0 else { return }
        if indexes.isEmpty { warmUp(); return }
        generation += 1
        typedAfter = ""
        let gen = generation
        queue.async {
            guard let fix = self.correction(typed, lang, auto: mode == 2) else { return }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }        // user typed further
                guard let after = self.typedAfter else { return }
                if mode == 2 {
                    guard after.isEmpty else { return }          // the user already typed on: don't touch
                    self.replace(orig: typed, fix: fix, boundary: boundary)
                    Stats.add(.spellAccepted)
                    Log.write("spell: auto")
                } else {
                    self.offer = (typed, fix, boundary)
                    let placed = self.showPanel(fix)
                    Stats.add(.spellShown)
                    Log.write("spell: offered (\(placed)) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
                }
            }
        }
    }

    /// Every key. Letters of the next word keep the plaque; Tab accepts, Esc hides, anything else ends it.
    /// Returns true if the key was used.
    func keyDown(code: UInt16, flags: CGEventFlags, char: String?) -> Bool {
        keysSinceApply += 1
        let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        if isOffering && plain && !flags.contains(.maskShift) {
            if code == 48 { accept(); return true }
            if code == 53 { dismiss(); return true }
        }
        if typedAfter != nil, plain, let c = char, c.count == 1, let ch = c.first,
           ch.isLetter || ch == "'" || ch == "-" {
            typedAfter! += c                                   // typing the next word: keep the offer
            return false
        }
        if typedAfter != nil, plain, code == 51, let t = typedAfter, !t.isEmpty {
            typedAfter!.removeLast()
            return false
        }
        generation += 1
        dismiss()
        return false
    }

    func dismiss() {
        offer = nil
        typedAfter = nil
        autoHide?.cancel()
        panel.orderOut(nil)
    }

    private func accept() {
        guard let o = offer else { return }
        let after = typedAfter ?? ""
        dismiss()
        // erase "<typo><boundary><next word so far>", type it back fixed
        Injector.backspaces(o.orig.count + o.boundary.count + after.count)
        Injector.type(o.fix + o.boundary + after)
        applied = (o.orig, o.fix, o.boundary)
        keysSinceApply = 0
        Stats.add(.spellAccepted)
        Log.write("spell: accepted")
    }

    private func replace(orig: String, fix: String, boundary: String) {
        Injector.backspaces(orig.count + boundary.count)
        Injector.type(fix + boundary)
        applied = (orig, fix, boundary)
        keysSinceApply = 0
    }

    /// ⌃⌥Z right after a fix: brings back what was typed and remembers the word.
    func undoLast() -> Bool {
        guard let a = applied, keysSinceApply <= 1 else { return false }
        applied = nil
        Injector.backspaces(a.fix.count + a.boundary.count)
        Injector.type(a.orig + a.boundary)
        if let lang = LayoutManager.shared.currentLang {
            let w = TextNorm.normalize(a.orig, lang)
            _ = UserStore.shared.touch(.word, lang, w, uses: 1)
        }
        Stats.add(.spellUndone)
        Log.write("spell: undone")
        return true
    }

    /// Hotkey: fix the word just typed (or being typed). `typed` is on screen, followed by `boundary`.
    func fixNow(_ typed: String, lang: Lang, boundary: String) {
        if indexes.isEmpty { warmUp() }
        queue.async {
            let fix = self.correction(typed, lang, auto: false)
            DispatchQueue.main.async {
                guard let fix = fix else { Notifier.show(L.t("spell.none")); return }
                self.replace(orig: typed, fix: fix, boundary: boundary)
            }
        }
    }

    // MARK: plaque

    @discardableResult
    private func showPanel(_ fix: String) -> String {
        label.stringValue = "\(fix)  ⇥"
        let size = label.fittingSize
        let w = size.width + 16, h = size.height + 8
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let origin: NSPoint
        var placed = "caret"
        if let r = CaretLocator.caretRect() {
            origin = NSPoint(x: r.minX - 4, y: primaryH - r.maxY - h - 4)
        } else if let f = CaretLocator.fieldRect() {
            origin = NSPoint(x: f.minX + 8, y: primaryH - f.maxY - h - 4)   // under the input field
            placed = "field"
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 12, y: m.y - h - 14)
            placed = "mouse"
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)
        bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
        label.frame = NSRect(x: 8, y: 4, width: size.width, height: size.height)
        panel.display()
        panel.orderFrontRegardless()
        autoHide?.cancel()
        let hideItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoHide = hideItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: hideItem)
        return placed
    }
}
