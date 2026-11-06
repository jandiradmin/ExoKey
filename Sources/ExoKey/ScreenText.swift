import AppKit
import ScreenCaptureKit
import Vision

/// Text on screen for apps that expose nothing through Accessibility (Telegram, WeChat, other Qt/Flutter apps):
/// a screenshot of the window, recognized on this Mac with Vision. Processed in memory only, never stored or sent.
enum ScreenText {
    struct Piece { let text: String; let rect: CGRect }   // global coordinates, top-left origin

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording once (the system shows its own dialog).
    static func requestOnce() {
        let d = UserDefaults.standard
        guard !allowed, !d.bool(forKey: "screenAsked") else { return }
        d.set(true, forKey: "screenAsked")
        DispatchQueue.main.async {
            Log.write("screen text: asking for Screen Recording")
            CGRequestScreenCaptureAccess()
        }
    }

    /// Recognized lines of the app's window that contains `near` (or its largest window). Blocking; call off the main thread.
    static func recognize(pid: pid_t, near: CGRect?) -> [Piece]? {
        guard allowed else { return nil }
        guard #available(macOS 14.0, *) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var image: CGImage?
        var frame = CGRect.zero
        Task.detached {
            defer { sem.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            let wins = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
            }
            let w = near.flatMap { n in wins.first { $0.frame.intersects(n) } }
                ?? wins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let win = w else { return }
            let cfg = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.frame.intersects(win.frame) }?.backingScaleFactor ?? 2
            cfg.width = Int(win.frame.width * scale)
            cfg.height = Int(win.frame.height * scale)
            cfg.showsCursor = false
            image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win),
                                                                configuration: cfg)
            frame = win.frame
        }
        guard sem.wait(timeout: .now() + 2) == .success, let img = image else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ru-RU", "uk-UA", "en-US"]
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: img).perform([req]) } catch { return nil }
        return (req.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return Piece(text: t, rect: CGRect(x: frame.minX + b.minX * frame.width,
                                               y: frame.minY + (1 - b.maxY) * frame.height,
                                               width: b.width * frame.width, height: b.height * frame.height))
        }
    }
}
