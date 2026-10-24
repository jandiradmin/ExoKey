import AppKit

/// Learns how the user writes (opt-in): keeps the user's own finished sentences locally and shows a few
/// of them to the model as examples. Also keeps anonymous-free local samples "context → suggestion → what was written"
/// to measure suggestion quality. Nothing leaves the Mac.
final class StyleMemory {
    static let shared = StyleMemory()
    private let store = UserStore.shared

    struct Shown { let draft: String; let suggestion: String; var accepted: Bool; let context: String; let app: String }
    var lastShown: Shown?

    private var samplesURL: URL { UserStore.dir.appendingPathComponent("ai-samples.jsonl") }

    func examples(app: String?, lang: Lang, limit: Int) -> [String] {
        store.styleExamples(app: app, lang: lang, limit: limit)
    }

    /// Called with the field text when a sentence or message is finished.
    func capture(fieldText: String, app: String) {
        guard Settings.shared.aiLearnStyle else { return }
        guard let sentence = Self.lastSentence(fieldText) else { return }
        let lang = Self.detectLang(sentence) ?? LayoutManager.shared.currentLang ?? .en
        store.styleAdd(sentence, app: app, lang: lang)
        if let s = lastShown {
            writeSample(s, final: sentence)
            lastShown = nil
        }
    }

    func clear() {
        store.styleClear()
        try? FileManager.default.removeItem(at: samplesURL)
    }

    // MARK: helpers

    static func lastSentence(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.lastIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
        // last sentence including its end mark
        let chars = Array(t)
        var end = chars.count
        while end > 0, " ".contains(chars[end - 1]) { end -= 1 }
        var start = end - 1
        while start > 0 {
            let c = chars[start - 1]
            if ".!?…".contains(c) && start < end - 1 { break }
            start -= 1
        }
        let s = String(chars[max(0, start)..<end]).trimmingCharacters(in: .whitespaces)
        let words = s.split(separator: " ").count
        guard words >= 3, words <= 40 else { return nil }
        if s.contains("http") || s.contains("@") || s.contains("://") { return nil }
        let letters = s.filter { $0.isLetter }.count
        guard Double(letters) / Double(max(1, s.count)) > 0.6 else { return nil }
        return s
    }

    static func detectLang(_ s: String) -> Lang? {
        let low = s.lowercased()
        if low.contains(where: { "іїєґ".contains($0) }) { return .uk }
        if low.contains(where: { "ыэъё".contains($0) }) { return .ru }
        if low.contains(where: { ("а"..."я").contains(String($0)) }) { return nil }
        if low.contains(where: { ("a"..."z").contains(String($0)) }) { return .en }
        return nil
    }

    private func writeSample(_ s: Shown, final: String) {
        let obj: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "app": s.app,
                                  "context": String(s.context.suffix(600)), "draft": String(s.draft.suffix(300)),
                                  "suggestion": s.suggestion, "accepted": s.accepted, "final": final]
        guard let d = try? JSONSerialization.data(withJSONObject: obj), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: samplesURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: samplesURL, atomically: true, encoding: .utf8)
        }
    }
}
