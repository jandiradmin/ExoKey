import UIKit

/// "@Марина" → the matching contacts in the suggestion bar → tap one → this card: checkboxes choose what to insert
/// (name, phone, e-mail, company), as the contact picker on the Mac. The chosen kinds are remembered.
final class ContactCard: UIView {
    var onInsert: ((String) -> Void)?
    var onClose: (() -> Void)?

    private enum Kind: String { case name, phone, email, company }
    private var items: [(kind: Kind, value: String, sw: UISwitch)] = []
    private static let key = "contactFields"

    init(_ c: People.Contact) {
        super.init(frame: .zero)
        backgroundColor = .systemGroupedBackground          // never clear (lost touches)
        let kinds = Set((KLog.defaults.stringArray(forKey: Self.key) ?? ["name", "phone"]).compactMap(Kind.init(rawValue:)))
        let title = UILabel()
        title.text = c.name
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        var rows: [UIView] = [title]
        func add(_ k: Kind, _ label: String, _ v: String, first: Bool) {
            guard !v.isEmpty else { return }
            let sw = UISwitch()
            sw.isOn = first && kinds.contains(k)
            let l = UILabel()
            l.text = label + v
            l.font = .systemFont(ofSize: 15)
            l.lineBreakMode = .byTruncatingMiddle
            let h = UIStackView(arrangedSubviews: [l, sw])
            h.axis = .horizontal
            h.spacing = 8
            rows.append(h)
            items.append((k, v, sw))
        }
        add(.name, "", c.name, first: true)
        for (i, p) in c.phones.enumerated() { add(.phone, "☎︎ ", p, first: i == 0) }
        for (i, e) in c.emails.enumerated() { add(.email, "✉︎ ", e, first: i == 0) }
        if c.company != c.name { add(.company, "🏢 ", c.company, first: true) }

        let cancel = UIButton(type: .system)
        cancel.setTitle("Отмена", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17)
        cancel.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        let insert = UIButton(type: .system)
        insert.setTitle("Вставить", for: .normal)
        insert.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        insert.addAction(UIAction { [weak self] _ in self?.insert() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancel, insert])
        buttons.distribution = .fillEqually
        rows.append(buttons)

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func insert() {
        let on = items.filter { $0.sw.isOn }
        // remember the kinds chosen (any value of the kind counts)
        KLog.defaults.set(Array(Set(on.map(\.kind.rawValue))), forKey: Self.key)
        let text = on.map(\.value).joined(separator: ", ")
        if text.isEmpty { onClose?() } else { onInsert?(text) }
    }
}
