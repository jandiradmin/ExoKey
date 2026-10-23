import Foundation

/// Diagnostic log without typed text: ~/Library/Logs/ExoKey.log
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ExoKey.log")
    private static let q = DispatchQueue(label: "exokey.log")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        q.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
