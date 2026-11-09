import Foundation

/// Debug log kept in the shared settings (written through the system even without Full Access);
/// read from the Mac with ios/pull_log.sh. Contains typed words — prototype only.
enum KLog {
    static let group = "group.com.jandiradmin.exokeymobile"
    static let defaults = UserDefaults(suiteName: group) ?? .standard
    private static let queue = DispatchQueue(label: "klog")
    private static var pending: [String] = []
    private static var flushing = false
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static var enabled: Bool { defaults.object(forKey: "log") as? Bool ?? true }

    /// Library/ of the shared folder: the Mac can copy files from there (not from the folder's root).
    private static let fileURL: URL? = {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let url = root.appendingPathComponent("Library/keyboard.log")
        // the log of the previous build lay in the root: keep it
        let old = root.appendingPathComponent("keyboard.log")
        if let data = try? Data(contentsOf: old) {
            if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() }
            else { try? data.write(to: url) }
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }()

    static func write(_ s: String) {
        guard enabled else { return }
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async {
            pending.append(line)
            guard !flushing else { return }
            flushing = true
            // one small append per second, off the main thread
            queue.asyncAfter(deadline: .now() + 1) {
                let data = Data(pending.joined().utf8)
                pending = []
                flushing = false
                guard let url = fileURL else { return }
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    let size = (try? h.seekToEnd()) ?? 0
                    if size > 3_000_000 { try? h.truncate(atOffset: 0) }
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
}

import QuartzCore

/// Key handling times, written to the log every 50 keys (avg / max, ms).
enum Speed {
    enum Kind: String { case down, up, read, stall }
    private static var data: [Kind: (n: Int, sum: Double, max: Double)] = [:]
    static var lastAction = "-"
    static func add(_ k: Kind, _ dt: Double) {
        var d = data[k] ?? (0, 0, 0)
        d.n += 1; d.sum += dt; d.max = Swift.max(d.max, dt)
        data[k] = d
        if k == .up, d.n % 50 == 0 {
            let line = data.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) n=\($0.value.n) avg=\(String(format: "%.1f", $0.value.sum / Double($0.value.n) * 1000)) max=\(String(format: "%.1f", $0.value.max * 1000))" }
                .joined(separator: "  ")
            KLog.write("speed ms: \(line)")
            data = [:]
        }
    }
}
