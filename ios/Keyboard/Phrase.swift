import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Next 2–4 words from Apple's on-device model (runs in the system, not in the keyboard's memory).
/// An experiment: whether a keyboard may use it and how fast it is — everything goes to the debug log.
final class Phrase {
    static let shared = Phrase()
    private var task: Task<Void, Never>?
    private var checked = false

    /// Logs once whether the model can be used here.
    func checkOnce() {
        guard !checked else { return }
        checked = true
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let m = SystemLanguageModel.default
            KLog.write("phrase: availability=\(m.availability) ru=\(m.supportsLocale(Locale(identifier: "ru_RU"))) en=\(m.supportsLocale(Locale(identifier: "en_US")))")
        } else {
            KLog.write("phrase: iOS < 26, no on-device model")
        }
        #else
        KLog.write("phrase: no FoundationModels")
        #endif
    }

    func cancel() { task?.cancel(); task = nil }

    /// Asks for the continuation of `text` after a short pause; `done` runs on the main thread.
    func request(_ text: String, done: @escaping (String?) -> Void) {
        cancel()
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }
        task = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)       // typing on: don't ask yet
            guard !Task.isCancelled, case .available = SystemLanguageModel.default.availability else { return }
            let t0 = Date()
            let session = LanguageModelSession(instructions: """
                You continue the user's message. Reply with ONLY the next 2 to 4 words that most likely follow, \
                in the same language and style. No quotes, no explanations, never repeat the given text.
                """)
            do {
                let r = try await session.respond(to: String(text.suffix(400)),
                                                  options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 16))
                guard !Task.isCancelled else { return }
                let out = Self.clean(r.content)
                KLog.write("phrase: «\(text.suffix(40))» → «\(out ?? "-")» raw=«\(r.content)» \(Int(Date().timeIntervalSince(t0) * 1000))ms")
                await MainActor.run { done(out) }
            } catch {
                KLog.write("phrase: error \(error) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
        }
        #endif
    }

    /// First line, no quotes, at most 4 words.
    static func clean(_ s: String) -> String? {
        let line = s.split(separator: "\n").first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"«»“”'…"))
        let words = t.split(separator: " ").prefix(4)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
