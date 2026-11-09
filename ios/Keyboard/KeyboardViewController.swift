import UIKit

final class KeyboardViewController: UIInputViewController {
    private var keyboard: KeyboardView!
    private var height: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard = KeyboardView(controller: self)
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        keyboard.showGlobe = needsInputModeSwitchKey
        // 5 rows: digits + 3 letter rows + bottom row
        let screen = view.window?.windowScene?.screen.bounds.size ?? view.bounds.size
        let landscape = screen.width > screen.height
        let pad = traitCollection.userInterfaceIdiom == .pad
        let rowH: CGFloat = pad ? (landscape ? 64 : 58) : (landscape ? 40 : 54)
        let h = rowH * 5 + 10 + KeyboardView.barHeight
        if height == nil {
            height = view.heightAnchor.constraint(equalToConstant: h)
            height?.priority = .defaultHigh + 1
            height?.isActive = true
        } else if height?.constant != h {
            height?.constant = h
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboard.autoShift()
        People.shared.reload(self)
    }

    // No touch observers on the system views (after adding those, far fewer touches reached the keyboard).
    // Only one thing is changed: iOS held touches near the screen edges while checking for its own edge swipe
    // (⌫ and ф arrived 120–180 ms late instead of ~25 ms) — keys must not wait for that.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        var v: UIView? = view
        while let cur = v {
            for g in cur.gestureRecognizers ?? [] where g.delaysTouchesBegan { g.delaysTouchesBegan = false }
            v = cur.superview
        }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        keyboard.cursorMoved = true
        keyboard.scheduleRefresh()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        keyboard.scheduleRefresh()
    }
}
