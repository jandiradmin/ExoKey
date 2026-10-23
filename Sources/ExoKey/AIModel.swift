import Foundation

/// Local language model: on-demand download of llama.cpp server + GGUF model, and the server process.
final class AIModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = AIModel()

    // Pinned versions
    static let engineURL = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b11840/llama-b11840-bin-macos-arm64.tar.gz")!
    static let modelURL = URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q8_0.gguf")!
    static let modelName = "Qwen3-4B-Instruct-2507 (Q8_0)"
    static let modelBytes: Int64 = 4_280_000_000
    static let port = 8737

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
    private var modelFile: URL { dir.appendingPathComponent("model.gguf") }
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
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                if self.state == .ready || self.state == .starting { self.state = self.isInstalled ? .installed : .notInstalled }
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

    func stop() {
        process?.terminate()
        process = nil
        if isInstalled { state = .installed }
    }

    // MARK: Completion

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
