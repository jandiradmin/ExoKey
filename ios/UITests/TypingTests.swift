import XCTest

/// The test robot: taps ExoKey keys on the real iPhone and checks what reached the text.
/// Run: ios/run_typing_test.sh  (the ExoKey keyboard must be the selected keyboard in the app's field)
final class TypingTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    private func field() -> XCUIElement {
        let f = app.descendants(matching: .any)["testField"].firstMatch
        XCTAssertTrue(f.waitForExistence(timeout: 5), "no test field")
        return f
    }

    private func key(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func text(_ f: XCUIElement) -> String { (f.value as? String) ?? "" }

    /// Lists what the robot can see of the keyboard (first run: are the keys visible at all?).
    func test0_seeKeys() {
        let f = field()
        f.tap()
        sleep(1)
        let keys = app.descendants(matching: .key)
        print("ROBOT keys visible: \(keys.count)")
        for i in 0..<min(keys.count, 60) { print("ROBOT key \(keys.element(boundBy: i).label) \(keys.element(boundBy: i).frame)") }
        if keys.count == 0 { print(app.debugDescription) }
    }

    /// The same key N times, as fast as the robot can: every tap must reach the text.
    func test1_sameKey() {
        let f = field()
        f.tap()
        sleep(1)
        let k = key("о")
        XCTAssertTrue(k.waitForExistence(timeout: 3), "key о not found")
        let before = text(f).filter { $0 == "о" }.count
        let start = Date()
        let n = 30
        // coordinates, so the robot doesn't look the key up again before every tap
        let c = k.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<n { c.tap() }
        let dt = Date().timeIntervalSince(start)
        sleep(1)
        let got = text(f).filter { $0 == "о" }.count - before
        print("ROBOT sameKey: tapped \(n) in \(String(format: "%.1f", dt)) s (\(String(format: "%.1f", Double(n) / dt))/s), reached text \(got)")
    }

    /// The same key, fast: the robot's own multi-tap (much faster than separate taps).
    func test3_fastSameKey() {
        let f = field()
        f.tap()
        sleep(1)
        let k = key("о")
        XCTAssertTrue(k.waitForExistence(timeout: 3), "key о not found")
        var total = 0, reached = 0
        for n in [10, 10, 10, 10, 10] {
            let before = text(f).filter { $0 == "о" }.count
            let start = Date()
            k.tap(withNumberOfTaps: n, numberOfTouches: 1)
            let dt = Date().timeIntervalSince(start)
            sleep(1)
            let got = text(f).filter { $0 == "о" }.count - before
            print("ROBOT fast: \(n) taps in \(String(format: "%.2f", dt)) s, reached text \(got)")
            total += n; reached += got
        }
        print("ROBOT fast total: \(reached) of \(total) (lost \(total - reached))")
    }

    /// A phrase with spaces: letters and spaces must all arrive, in order.
    func test2_phrase() {
        let f = field()
        f.tap()
        sleep(1)
        let phrase = "привет как дела у тебя все хорошо"
        let start = Date()
        var coords: [Character: XCUICoordinate] = [:]
        for ch in Set(phrase) {
            let k = key(ch == " " ? "␣" : String(ch))
            if k.exists { coords[ch] = k.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)) }
        }
        for ch in phrase { coords[ch]?.tap() }
        let dt = Date().timeIntervalSince(start)
        sleep(1)
        let t = text(f)
        print("ROBOT phrase: \(phrase.count) taps in \(String(format: "%.1f", dt)) s (\(String(format: "%.1f", Double(phrase.count) / dt))/s)")
        print("ROBOT phrase result: «\(t)»")
    }

    /// The Russian layout must be on: otherwise swipe along the space bar.
    private func ensureRussian() {
        for _ in 0..<3 {
            if key("й").exists { return }
            let sp = key("␣")
            guard sp.exists else { return }
            let from = sp.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: sp.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            sleep(1)
        }
    }

    /// Types `phrase` with exact timing: a new key every `every` s, each held `hold` s (hold > every = two thumbs overlap).
    /// Returns what reached the text.
    private func typeFast(_ phrase: String, every: Double, hold: Double, _ f: XCUIElement) -> String {
        ensureRussian()
        var centers: [Character: CGPoint] = [:]
        for ch in Set(phrase) {
            let k = key(ch == " " ? "␣" : String(ch))
            if k.exists { let r = k.frame; centers[ch] = CGPoint(x: r.midX, y: r.midY) }
        }
        let before = text(f)
        let rec = XCSynthesizedEventRecord(name: "typing", interfaceOrientation: .portrait)!
        for (i, ch) in phrase.enumerated() {
            guard var p = centers[ch] else { continue }
            // fingers never hit the exact centre twice
            p.x += CGFloat.random(in: -4...4); p.y += CGFloat.random(in: -4...4)
            let path = XCPointerEventPath(forTouchAt: p, offset: Double(i) * every)!
            path.liftUp(atOffset: Double(i) * every + hold)
            rec.add(path)
        }
        try? rec.synthesize()
        sleep(2)
        let after = text(f)
        return after.hasPrefix(before) ? String(after.dropFirst(before.count)) : after
    }

    /// Letters missing in `got` compared with `want` (lower case, in order).
    private func lost(_ want: String, _ got: String) -> Int {
        let a = Array(want.lowercased()), b = Array(got.lowercased())
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { for j in 0...b.count {
            if i == 0 || j == 0 { d[i][j] = 0 } else { d[i][j] = a[i - 1] == b[j - 1] ? d[i - 1][j - 1] + 1 : max(d[i - 1][j], d[i][j - 1]) }
        } }
        return a.count - d[a.count][b.count]
    }

    /// A phrase at human speeds, with and without two thumbs overlapping.
    func test4_fastPhrase() {
        let f = field()
        f.tap()
        sleep(1)
        let phrase = "привет как дела у тебя все хорошо давай встретимся в субботу утром "
        var total = 0, missing = 0
        for (every, hold) in [(0.20, 0.08), (0.15, 0.08), (0.12, 0.09), (0.10, 0.12), (0.08, 0.12)] {
            let got = typeFast(phrase, every: every, hold: hold, f)
            let l = lost(phrase, got)
            total += phrase.count; missing += l
            print("ROBOT \(Int(1 / every))/s hold \(Int(hold * 1000))ms: lost \(l) of \(phrase.count) «\(got)»")
        }
        print("ROBOT phrase total: lost \(missing) of \(total)")
    }

    /// Like a person: uneven rhythm (0.12–0.45 s), uneven press (0.05–0.2 s), sometimes two thumbs overlap.
    func test5_humanLike() {
        let f = field()
        f.tap()
        sleep(1)
        ensureRussian()
        let phrases = ["как дела ты смотрел новый телевизор ", "что думаешь оно того стоит или подождать ",
                       "давай обсудим модели и цены завтра ", "мне нужно подумать до субботы "]
        var total = 0, missing = 0
        for (n, phrase) in phrases.enumerated() {
            var centers: [Character: CGPoint] = [:]
            for ch in Set(phrase) {
                let k = key(ch == " " ? "␣" : String(ch))
                if k.exists { let r = k.frame; centers[ch] = CGPoint(x: r.midX, y: r.midY) }
            }
            let before = text(f)
            let rec = XCSynthesizedEventRecord(name: "human \(n)", interfaceOrientation: .portrait)!
            var t = 0.0
            for ch in phrase {
                guard var p = centers[ch] else { continue }
                p.x += CGFloat.random(in: -6...6); p.y += CGFloat.random(in: -6...6)
                let path = XCPointerEventPath(forTouchAt: p, offset: t)!
                path.liftUp(atOffset: t + Double.random(in: 0.05...0.2))
                rec.add(path)
                t += Double.random(in: 0.12...0.45)
            }
            try? rec.synthesize()
            sleep(2)
            let after = text(f)
            let got = after.hasPrefix(before) ? String(after.dropFirst(before.count)) : after
            let l = lost(phrase, got)
            total += phrase.count; missing += l
            print("ROBOT human \(n): lost \(l) of \(phrase.count) «\(got)»")
        }
        print("ROBOT human total: lost \(missing) of \(total)")
    }

    /// A real swipe along the space bar still switches the language (and back).
    func test6_spaceSwipe() {
        let f = field()
        f.tap()
        sleep(1)
        ensureRussian()
        let sp = key("␣")
        // a quick flick: short press, fast drag
        let swipe = { sp.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.01, thenDragTo: sp.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0) }
        swipe(); sleep(1)
        let en = key("q").exists
        swipe(); sleep(1)
        let ru = key("й").exists
        print("ROBOT swipe: to EN \(en ? "ok" : "FAILED"), back to RU \(ru ? "ok" : "FAILED"), text «\(text(f))»")
    }

    /// Words with pauses (thinking between words), like real chat typing: the first key after a pause must work.
    func test7_pauses() {
        let f = field()
        f.tap()
        sleep(1)
        ensureRussian()
        let phrase = "я проверяю как печатает клавиатура после паузы и пробела "
        var centers: [Character: CGPoint] = [:]
        for ch in Set(phrase) {
            let k = key(ch == " " ? "␣" : String(ch))
            if k.exists { let r = k.frame; centers[ch] = CGPoint(x: r.midX, y: r.midY) }
        }
        let before = text(f)
        let rec = XCSynthesizedEventRecord(name: "pauses", interfaceOrientation: .portrait)!
        var t = 0.0
        for ch in phrase {
            guard let p = centers[ch] else { continue }
            let path = XCPointerEventPath(forTouchAt: p, offset: t)!
            path.liftUp(atOffset: t + 0.08)
            rec.add(path)
            t += ch == " " ? Double.random(in: 0.6...1.5) : 0.18      // a pause after each word
        }
        try? rec.synthesize()
        sleep(2)
        let after = text(f)
        let got = after.hasPrefix(before) ? String(after.dropFirst(before.count)) : after
        print("ROBOT pauses: lost \(lost(phrase, got)) of \(phrase.count) «\(got)»")
    }

    /// A typo left behind, more words typed, then the "↩ fix" button fixes it in place.
    func test8_previousWordButton() {
        let f = field()
        f.tap()
        sleep(1)
        ensureRussian()
        _ = typeFast("я работл весь день ", every: 0.25, hold: 0.08, f)
        sleep(1)
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "↩")).firstMatch
        let seen = chip.waitForExistence(timeout: 2)
        print("ROBOT chip: \(seen ? chip.label : "none"), text before «\(text(f))»")
        if seen { chip.tap(); sleep(1) }
        print("ROBOT chip: text after «\(text(f))»")
    }
}
