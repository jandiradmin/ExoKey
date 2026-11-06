import Foundation

/// Local language model: on-demand download of llama.cpp server + GGUF model, and the server process.
final class AIModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = AIModel()

    // Pinned versions
    static let engineURL = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11840/llama-b11840-bin-macos-arm64.tar.gz")!
    struct Variant {
        let file: String, url: URL, name: String, bytes: Int64, sizeText: String
    }
    // Base (not chat) models: trained to continue text, they predict the user's next words better
    // (tools/test/prompt_bench.py on real samples: 17% vs 14% exact next word, more right guesses when sure).
    static let variants: [AIVariant: Variant] = [
        .fast: Variant(file: "model-base.gguf",
                       url: URL(string: "https://huggingface.co/mradermacher/Qwen3-4B-Base-GGUF/resolve/main/Qwen3-4B-Base.Q4_K_M.gguf")!,
                       name: "Qwen3-4B-Base (Q4_K_M)", bytes: 2_497_280_736, sizeText: "2,5"),
        .quality: Variant(file: "model-base-q8.gguf",
                          url: URL(string: "https://huggingface.co/mradermacher/Qwen3-4B-Base-GGUF/resolve/main/Qwen3-4B-Base.Q8_0.gguf")!,
                          name: "Qwen3-4B-Base (Q8_0)", bytes: 4_280_405_216, sizeText: "4,3"),
    ]
    static var current: Variant { variants[Settings.shared.aiVariant]! }
    static var modelURL: URL { current.url }
    static var modelName: String { current.name }
    static var modelBytes: Int64 { current.bytes }
    static let port = 8737
    /// The first word is shown only if the model is at least this sure of it (careful / normal / bold).
    static var minFirstWordProb: Double { [0.12, 0.05, 0.03, 0.0][min(3, Settings.shared.aiConfidence)] }
    // prompt_bench on real samples (4B Base): 0.12 → shown 14%, right 55%; 0.05 → 29%, 40%; 0.03 → 40%, 34%
    /// Further words: each token at least this sure.
    static var minTokenProb: Double { [0.45, 0.30, 0.20, 0.05][min(3, Settings.shared.aiConfidence)] }
    // 3 = "like Cotypist": always show the model's continuation (only misspelled words are cut)

    enum State: Equatable {
        case notInstalled
        case downloading(Double)      // 0...1
        case installed                // files present, server stopped
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    private var dir: URL { UserStore.dir.appendingPathComponent("ai", isDirectory: true) }
    private var modelFile: URL { dir.appendingPathComponent(Self.current.file) }

    /// Called when the user picks another model variant.
    func variantChanged() {
        stop()
        task?.cancel(); task = nil
        state = isInstalled ? .installed : .notInstalled
        if Settings.shared.aiEnabled { start() }
    }
    private var engineDir: URL { dir.appendingPathComponent("engine", isDirectory: true) }
    private var serverBinary: URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: engineDir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.lastPathComponent == "llama-server" { return u }
        return nil
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: modelFile.path) && serverBinary != nil }

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var phase = 0   // 1 = engine, 2 = model
    private var process: Process?

    override private init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        state = isInstalled ? .installed : .notInstalled
    }

    // MARK: Download

    func download() {
        if case .downloading = state { return }
        state = .downloading(0)
        Log.write("ai: download start")
        if serverBinary == nil {
            phase = 1
            task = session.downloadTask(with: Self.engineURL)
        } else {
            phase = 2
            task = session.downloadTask(with: Self.modelURL)
        }
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = isInstalled ? .installed : .notInstalled
    }

    func remove() {
        stop()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        state = .notInstalled
        Settings.shared.aiEnabled = false
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        let engineShare = 0.01
        if phase == 1 {
            let p = t > 0 ? Double(w) / Double(t) : 0
            state = .downloading(p * engineShare)
        } else {
            let total = t > 0 ? t : Self.modelBytes
            state = .downloading(engineShare + (1 - engineShare) * Double(w) / Double(total))
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
        let fm = FileManager.default
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            state = .failed("HTTP \(http.statusCode)")
            return
        }
        do {
            if phase == 1 {
                let tgz = dir.appendingPathComponent("engine.tgz")
                try? fm.removeItem(at: tgz)
                try fm.moveItem(at: loc, to: tgz)
                try? fm.removeItem(at: engineDir)
                try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                p.arguments = ["xzf", tgz.path, "-C", engineDir.path]
                try p.run(); p.waitUntilExit()
                try? fm.removeItem(at: tgz)
                guard serverBinary != nil else { state = .failed("engine"); return }
                phase = 2
                task = session.downloadTask(with: Self.modelURL)
                task?.resume()
            } else {
                try? fm.removeItem(at: modelFile)
                try fm.moveItem(at: loc, to: modelFile)
                task = nil
                state = .installed
                Log.write("ai: download done")
                if Settings.shared.aiEnabled { start() }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error as NSError? else { return }
        if e.code == NSURLErrorCancelled { return }
        state = .failed(e.localizedDescription)
        Log.write("ai: download error \(e.code)")
    }

    // MARK: Server

    /// LoRA add-ons trained for autocomplete. Files: ai/lora-textbook.gguf, ai/lora-mystyle.gguf
    enum Adapter: String, CaseIterable { case textbook, mystyle }
    private(set) var loadedAdapters: [Adapter] = []
    func adapterFile(_ a: Adapter) -> URL { dir.appendingPathComponent("lora-\(a.rawValue).gguf") }
    func hasAdapter(_ a: Adapter) -> Bool { FileManager.default.fileExists(atPath: adapterFile(a).path) }
    /// Per-request scales: "Мой стиль" already contains the textbook data, so it replaces it when on.
    private var loraBody: [[String: Any]] {
        let s = Settings.shared
        let on: Adapter? = s.aiMyStyle && loadedAdapters.contains(.mystyle) ? .mystyle
            : (s.aiTextbook && loadedAdapters.contains(.textbook) ? .textbook : nil)
        return loadedAdapters.enumerated().map { ["id": $0.offset, "scale": $0.element == on ? 1.0 : 0.0] }
    }

    func start() {
        guard Settings.shared.aiMode == .model, isInstalled, process == nil, let bin = serverBinary else { return }
        state = .starting
        // kill a server left over from a previous ExoKey run
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "ExoKey/ai/engine/"]
        try? k.run(); k.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        let p = Process()
        p.executableURL = bin
        p.currentDirectoryURL = bin.deletingLastPathComponent()
        p.arguments = ["-m", modelFile.path, "--host", "127.0.0.1", "--port", String(Self.port),
                       "-c", "4096", "-ngl", "99", "--parallel", "1"]
        // add-ons ("Учебник", "Мой стиль"): loaded once, switched on/off per request without a restart
        loadedAdapters = Adapter.allCases.filter { FileManager.default.fileExists(atPath: adapterFile($0).path) }
        if !loadedAdapters.isEmpty {
            p.arguments! += ["--lora-init-without-apply"]
            for a in loadedAdapters { p.arguments! += ["--lora", adapterFile(a).path] }
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.process === p else { return }   // our own stop() clears process first
                self.process = nil
                let wasRunning = self.state == .ready || self.state == .starting
                if wasRunning { self.state = self.isInstalled ? .installed : .notInstalled }
                // the server died (killed, crashed, out of memory): bring it back instead of silently going without AI
                if wasRunning, Settings.shared.aiEnabled, Settings.shared.aiMode == .model {
                    self.restarts += 1
                    Log.write("ai: server stopped unexpectedly, restarting (\(self.restarts))")
                    let delay = self.restarts > 5 ? 60.0 : 2.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
            Log.write("ai: server started")
            waitHealthy(attempt: 0)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func waitHealthy(attempt: Int) {
        guard process != nil else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if (resp as? HTTPURLResponse)?.statusCode == 200 {
                    self.state = .ready
                    Log.write("ai: ready")
                } else if attempt < 120 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitHealthy(attempt: attempt + 1) }
                } else {
                    self.state = .failed("server timeout")
                }
            }
        }.resume()
    }

    private var restarts = 0

    func stop() {
        let p = process
        process = nil
        p?.terminate()
        if isInstalled { state = .installed }
    }

    // MARK: Completion

    /// Streams the completion: `onUpdate(accumulatedText, done, cutByTokenLimit)` on the main queue.
    @discardableResult
    func stream(_ prompt: String, maxTokens: Int, onUpdate: @escaping (String, Bool, Bool) -> Void) -> Task<Void, Never>? {
        guard state == .ready else { return nil }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/completion")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": maxTokens, "temperature": 0,
                                   "cache_prompt": true, "stop": ["\n"], "stream": true,
                                   "n_probs": 1, "post_sampling_probs": false, "lora": loraBody]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Only the confident part is shown: nothing until the first word is complete and likely enough,
        // then words while every token stays likely.
        let minFirst = Self.minFirstWordProb, minToken = Self.minTokenProb
        return Task {
            var acc = ""
            var total = 1.0
            var firstDone = false
            func firstWordComplete(_ s: String) -> Bool {
                let t = s.drop { $0 == " " }
                guard let i = t.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return false }
                return t[i...].contains { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-") }
            }
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: req)
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    let piece = obj["content"] as? String ?? ""
                    var p = 1.0
                    if let probs = obj["completion_probabilities"] as? [[String: Any]] {
                        for t in probs { if let lp = t["logprob"] as? Double { p *= exp(lp) } }
                    }
                    let done = (obj["stop"] as? Bool) == true
                    // base models sometimes drift into another script (Chinese etc.) — never part of the user's text
                    if piece.unicodeScalars.contains(where: { (0x2E80...0xD7FF).contains($0.value) || (0xF900...0xFFEF).contains($0.value) }) {
                        let snapshot = firstDone ? acc : ""
                        await MainActor.run { onUpdate(snapshot, true, false) }
                        return
                    }
                    if firstDone, !piece.isEmpty, p < minToken {
                        // unsure from here on: finish with what we have
                        let midWord = !(piece.first?.isWhitespace ?? true) && (acc.last?.isLetter ?? false) && (piece.first?.isLetter ?? false)
                        let snapshot = acc
                        await MainActor.run { onUpdate(snapshot, true, midWord) }
                        return
                    }
                    total *= p
                    acc += piece
                    if !firstDone {
                        guard firstWordComplete(acc) || done else { continue }
                        if total < minFirst {
                            await MainActor.run { onUpdate("", true, false) }
                            return
                        }
                        firstDone = true
                    }
                    let cut = (obj["stopped_limit"] as? Bool) == true || (obj["stop_type"] as? String) == "limit"
                    let snapshot = acc
                    await MainActor.run { onUpdate(snapshot, done, cut) }
                    if done { return }
                }
            } catch {}
            if !Task.isCancelled {
                let snapshot = firstDone || total >= minFirst ? acc : ""
                await MainActor.run { onUpdate(snapshot, true, false) }
            }
        }
    }

    /// The model's ending of the word being typed and the probability of that ending (context-aware:
    /// "please give me the expl" → "anation", where the dictionary alone would say "ain").
    func wordCompletion(_ prompt: String, done: @escaping (String, Double) -> Void) {
        guard state == .ready else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/completion")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": 8, "temperature": 0, "cache_prompt": true,
                                   "stop": ["\n"], "n_probs": 1, "lora": loraBody]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let probs = obj["completion_probabilities"] as? [[String: Any]] else { return }
            var acc = "", total = 1.0
            for t in probs {
                let piece = t["token"] as? String ?? ""
                let letters = String(piece.prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })
                acc += letters
                total *= exp(t["logprob"] as? Double ?? -99)
                if letters.count < piece.count { break }
            }
            DispatchQueue.main.async { done(acc, total) }
        }.resume()
    }

    /// The model's most likely next tokens with probabilities (one step only — fast).
    func nextTokens(_ prompt: String, k: Int = 12, done: @escaping ([(token: String, p: Double)]) -> Void) {
        guard state == .ready else { done([]); return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/completion")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": 1, "temperature": 0, "cache_prompt": true,
                                   "n_probs": k, "lora": loraBody]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var out: [(String, Double)] = []
            if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let cp = obj["completion_probabilities"] as? [[String: Any]], let first = cp.first,
               let top = first["top_logprobs"] as? [[String: Any]] {
                for t in top { if let tok = t["token"] as? String, let lp = t["logprob"] as? Double { out.append((tok, exp(lp))) } }
            }
            DispatchQueue.main.async { done(out) }
        }.resume()
    }

    /// Returns (text, cutByTokenLimit).
    func complete(_ prompt: String, maxTokens: Int = 28, completion: @escaping (String?, Bool) -> Void) {
        guard state == .ready else { completion(nil, false); return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/completion")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "n_predict": maxTokens, "temperature": 0,
                                   "cache_prompt": true, "stop": ["\n"]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let text = obj?["content"] as? String
            let limit = (obj?["stopped_limit"] as? Bool) == true || (obj?["stop_type"] as? String) == "limit"
            DispatchQueue.main.async { completion(text, limit) }
        }.resume()
    }
}
