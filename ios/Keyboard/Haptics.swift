import UIKit

/// Key vibration that never holds up typing. Keyboards may only use the plain system feedback generator
/// (Core Haptics stayed silent here); it is fired a moment after the key has been handled.
final class Haptics {
    static let shared = Haptics()
    private let generator = UIImpactFeedbackGenerator(style: .light)
    /// A light tap at full force is the most it gives: the strong setting uses the medium tap.
    private let stronger = UIImpactFeedbackGenerator(style: .medium)
    /// weak, medium, strong (the crisp "rigid" one felt harsh). Raised by half on Yan's request:
    /// light 0.3 → 0.45, 0.55 → 0.83, 0.8 → medium 0.8.
    private let levels: [(medium: Bool, intensity: CGFloat)] = [(false, 0.45), (false, 0.83), (true, 0.8)]

    private init() { generator.prepare(); stronger.prepare() }

    func tap(strength: Int) {
        let level = levels[min(2, max(0, strength))]
        let i = level.intensity
        let generator = level.medium ? stronger : generator
        // after the letter is in: the key press never waits for the motor
        DispatchQueue.main.async { [generator] in
            generator.impactOccurred(intensity: i)
            generator.prepare()
        }
    }
}
