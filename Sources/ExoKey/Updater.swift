import AppKit
import CryptoKit

/// Checks GitHub releases for a newer version and installs it in one click:
/// download → SHA-256 check → signature check → replace the app → relaunch.
/// Only the public GitHub API is contacted; nothing about the user is sent.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "jandiradmin/ExoKey"

    struct Release { let version: String; let zip: URL; let sha: URL?; let page: URL }

    @Published private(set) var available: Release?
    @Published private(set) var installing = false
    private var timer: Timer?

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// First check shortly after launch, then once a day.
    func start() {
        guard Settings.shared.checkUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check(manual: false) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            guard Settings.shared.checkUpdates else { return }
            self?.check(manual: false)
        }
    }

    /// "1.10.0" > "1.9.2"
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: "-").first
                .map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(manual: Bool) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, error in
            let list = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            var found: Release?
            for r in list where (r["draft"] as? Bool) != true {
                guard let tag = r["tag_name"] as? String,
                      let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
                let assets = r["assets"] as? [[String: Any]] ?? []
                func asset(_ suffix: String) -> URL? {
                    assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                        .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
                }
                guard let zip = asset(".zip") else { continue }
                let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if found == nil || Self.isNewer(v, than: found!.version) {
                    found = Release(version: v, zip: zip, sha: asset(".zip.sha256"), page: page)
                }
            }
            DispatchQueue.main.async {
                if let f = found, Self.isNewer(f.version, than: Self.currentVersion) {
                    self.available = f
                    Log.write("update: \(f.version) available")
                    let d = UserDefaults.standard
                    if manual || d.string(forKey: "updateNotified") != f.version {
                        d.set(f.version, forKey: "updateNotified")
                        Notifier.show(L.t("upd.available", f.version))
                    }
                } else {
                    self.available = nil
                    if manual { Notifier.show(error == nil ? L.t("upd.latest", Self.currentVersion) : L.t("upd.failed")) }
                }
            }
        }.resume()
    }

    func install() {
        guard let r = available, !installing else { return }
        installing = true
        Notifier.show(L.t("upd.downloading", r.version))
        Log.write("update: downloading \(r.version)")
        URLSession.shared.downloadTask(with: r.zip) { tmp, _, _ in
            guard let tmp = tmp, let zipData = try? Data(contentsOf: tmp) else { return self.fail("download") }
            // checksum published next to the archive
            if let shaURL = r.sha {
                guard let shaText = try? String(contentsOf: shaURL, encoding: .utf8),
                      let expected = shaText.split(separator: " ").first.map(String.init) else { return self.fail("sha") }
                let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                guard actual.lowercased() == expected.lowercased() else { return self.fail("sha mismatch") }
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("exokey-update-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("ExoKey.zip")
            guard (try? zipData.write(to: zip)) != nil,
                  Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { return self.fail("unzip") }
            let newApp = work.appendingPathComponent("ExoKey.app")
            guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier,
                  Self.run("/usr/bin/codesign", ["--verify", "--deep", newApp.path]) == 0 else { return self.fail("signature") }
            DispatchQueue.main.async { self.replace(with: newApp) }
        }.resume()
    }

    /// A tiny script waits for this process to quit, swaps the app and starts the new one.
    private func replace(with newApp: URL) {
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target).old" && mv "\(target)" "\(target).old" && mv "\(newApp.path)" "\(target)" && rm -rf "\(target).old"
        xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        open "\(target)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do { try p.run() } catch { fail("relaunch"); return }
        Log.write("update: installing, relaunching")
        NSApp.terminate(nil)
    }

    private func fail(_ why: String) {
        DispatchQueue.main.async {
            self.installing = false
            Log.write("update: failed (\(why))")
            Notifier.show(L.t("upd.failed"))
            if let page = self.available?.page { NSWorkspace.shared.open(page) }
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
