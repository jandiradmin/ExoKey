import AppKit
import Contacts

/// "@name" in any text field: a small list of matching contacts; checkboxes choose what to insert.
final class ContactPicker: NSObject {
    static let shared = ContactPicker()

    enum Field: String, CaseIterable { case name, phone, email, company, address }

    private struct Entry {
        let name: String
        let tokens: [String]
        let phones: [(number: String, label: String)]
        let email: String
        let company: String
        let address: String
    }
    private struct Row { let entry: Entry; let phone: String; let phoneLabel: String }

    private let store = CNContactStore()
    private var entries: [Entry] = []
    private var loaded = false
    private var loading = false
    private var rows: [Row] = []
    private var selected = 0
    private var deleteCount = 0
    private var lastQueries: [String] = []
    private var anchor: NSPoint?
    private var fields: Set<Field>
    private let panel: PickerPanel
    private let d = UserDefaults.standard

    var isVisible: Bool { panel.isVisible }

    private override init() {
        let saved = UserDefaults.standard.stringArray(forKey: "contactFields") ?? ["name", "phone"]
        fields = Set(saved.compactMap(Field.init(rawValue:)))
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        super.init()
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.loaded = false
        }
    }

    // MARK: contacts

    /// Loads the address book (asks for access the first time).
    func ensureLoaded() {
        guard Settings.shared.contactsEnabled, !loaded, !loading else { return }
        let st = CNContactStore.authorizationStatus(for: .contacts)
        if st == .notDetermined {
            loading = true
            store.requestAccess(for: .contacts) { ok, _ in
                DispatchQueue.main.async {
                    self.loading = false
                    Log.write("contacts access: \(ok)")
                    if ok { self.load() }
                }
            }
            return
        }
        guard st == .authorized else { return }
        load()
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [Entry] = []
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPostalAddressesKey as CNKeyDescriptor,
            ]
            let req = CNContactFetchRequest(keysToFetch: keys)
            let addr = CNPostalAddressFormatter()
            do {
                try self.store.enumerateContacts(with: req) { c, _ in
                    let full = CNContactFormatter.string(from: c, style: .fullName) ?? ""
                    let name = full.isEmpty ? c.organizationName : full
                    guard !name.isEmpty else { return }
                    let tokens = [c.givenName, c.familyName, c.middleName, c.nickname, c.organizationName, full]
                        .map(Self.norm).filter { !$0.isEmpty }
                    let phones = c.phoneNumbers.map { lv -> (String, String) in
                        (Self.international(lv.value.stringValue),
                         lv.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "")
                    }
                    let a = c.postalAddresses.first.map {
                        addr.string(from: $0.value).replacingOccurrences(of: "\n", with: ", ")
                    } ?? ""
                    out.append(Entry(name: name, tokens: tokens, phones: phones,
                                     email: (c.emailAddresses.first?.value as String?) ?? "",
                                     company: c.organizationName, address: a))
                }
            } catch {
                Log.write("contacts load error: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.entries = out
                self.loaded = true
                self.loading = false
                Log.write("contacts loaded: \(out.count)")
                if !self.lastQueries.isEmpty, self.deleteCount > 0 { self.update(queries: self.lastQueries, typed: self.deleteCount - 1) }
            }
        }
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// "+1 (323) 504-06-80" → "+13235040680". Numbers without a country code: 0XXXXXXXXX → +38, 10 digits → +1.
    static func international(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let digits = String(t.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }.map(Character.init))
        if digits.isEmpty { return t }
        if t.hasPrefix("+") { return "+" + digits }
        if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
        if digits.count == 10 && digits.hasPrefix("0") { return "+38" + digits }
        if digits.count == 10 { return "+1" + digits }
        if digits.count == 11 && digits.hasPrefix("1") { return "+" + digits }
        if digits.count == 12 && digits.hasPrefix("380") { return "+" + digits }
        return digits
    }

    // MARK: entry points from Engine

    /// The word after "@" changed. `queries`: the typed keys read in every active layout.
    func update(queries: [String], typed: Int) {
        guard Settings.shared.contactsEnabled else { return }
        lastQueries = queries
        deleteCount = typed + 1                      // "@" + the word
        ensureLoaded()
        let qs = Set(queries.map(Self.norm).filter { !$0.isEmpty })
        var found: [(rank: Int, e: Entry)] = []
        for e in entries {
            var best = Int.max
            for q in qs {
                for (i, t) in e.tokens.enumerated() where t.hasPrefix(q) || (i == e.tokens.count - 1 && t.contains(" " + q)) {
                    best = min(best, i)
                }
            }
            if best != .max { found.append((best, e)) }
        }
        found.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.e.name.localizedCompare($1.e.name) == .orderedAscending }
        var r: [Row] = []
        for (_, e) in found.prefix(8) {
            if e.phones.count > 1 && fields.contains(.phone) {
                for p in e.phones { r.append(Row(entry: e, phone: p.number, phoneLabel: p.label)) }
            } else {
                r.append(Row(entry: e, phone: e.phones.first?.number ?? "", phoneLabel: e.phones.first?.label ?? ""))
            }
        }
        rows = Array(r.prefix(8))
        selected = 0
        if rows.isEmpty { panel.orderOut(nil); return }
        Predictor.shared.hide()
        render()
    }

    /// Keys while the list is shown. Returns true if the key was used.
    func handleKey(code: UInt16, flags: CGEventFlags) -> Bool {
        guard isVisible, flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
        switch code {
        case 125: move(1)
        case 126: move(-1)
        case 36, 76, 48: insert()
        case 53: close()
        case 18, 19, 20, 21, 23:
            let i = [18, 19, 20, 21, 23].firstIndex(of: Int(code))!
            toggle(Field.allCases[i])
        default: return false
        }
        return true
    }

    func close() {
        panel.orderOut(nil)
        rows = []
        anchor = nil
        lastQueries = []
        deleteCount = 0
    }

    /// Click position (CGEvent coordinates, top-left origin) is inside the list.
    func contains(_ p: CGPoint) -> Bool {
        guard isVisible else { return false }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return panel.frame.contains(NSPoint(x: p.x, y: primaryH - p.y))
    }

    // MARK: actions

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
        render()
    }

    private func toggle(_ f: Field) {
        if fields.contains(f) { fields.remove(f) } else { fields.insert(f) }
        d.set(Field.allCases.filter { fields.contains($0) }.map(\.rawValue), forKey: "contactFields")
        if f == .phone, !lastQueries.isEmpty { update(queries: lastQueries, typed: deleteCount - 1) } else { render() }
    }

    private func text(_ r: Row) -> String {
        var parts: [String] = []
        for f in Field.allCases where fields.contains(f) {
            let v: String
            switch f {
            case .name: v = r.entry.name
            case .phone: v = r.phone
            case .email: v = r.entry.email
            case .company: v = r.entry.company == r.entry.name ? "" : r.entry.company
            case .address: v = r.entry.address
            }
            if !v.isEmpty { parts.append(v) }
        }
        return parts.joined(separator: ", ")
    }

    private func insert() {
        guard selected < rows.count else { close(); return }
        let t = text(rows[selected])
        let n = deleteCount
        close()
        Engine.shared.reset()
        guard !t.isEmpty else { return }
        Injector.backspaces(n)
        Injector.type(t)
        Stats.add(.contactInserted)
        Log.write("contact inserted")
    }

    @objc private func rowClicked(_ b: NSButton) { selected = b.tag; insert() }
    @objc private func fieldClicked(_ b: NSButton) { toggle(Field.allCases[b.tag]) }

    // MARK: view

    private func render() {
        let w: CGFloat = 460
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (i, r) in rows.enumerated() {
            let s = NSMutableAttributedString(string: "  " + r.entry.name,
                                              attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                           .foregroundColor: NSColor.white])
            if !r.phone.isEmpty {
                s.append(NSAttributedString(string: "   " + r.phone,
                                            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                         .foregroundColor: NSColor(white: 0.8, alpha: 1)]))
            }
            if !r.phoneLabel.isEmpty, r.entry.phones.count > 1 {
                s.append(NSAttributedString(string: "  " + r.phoneLabel,
                                            attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                         .foregroundColor: NSColor(white: 0.6, alpha: 1)]))
            }
            let b = RowButton(title: "", target: self, action: #selector(rowClicked(_:)))
            b.attributedTitle = s
            b.tag = i
            b.highlighted(i == selected)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: w - 12).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(b)
        }

        let boxes = NSStackView()
        boxes.orientation = .horizontal
        boxes.spacing = 12
        for (i, f) in Field.allCases.enumerated() {
            let c = CheckBox(checkboxWithTitle: "\(i + 1) \(L.t("contacts.f." + f.rawValue))", target: self, action: #selector(fieldClicked(_:)))
            c.tag = i
            c.state = fields.contains(f) ? .on : .off
            c.font = NSFont.systemFont(ofSize: 12)
            boxes.addArrangedSubview(c)
        }
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last ?? stack)
        stack.addArrangedSubview(boxes)

        let preview = NSTextField(labelWithString: rows.isEmpty ? "" : "→ " + text(rows[selected]))
        preview.font = NSFont.systemFont(ofSize: 12)
        preview.textColor = NSColor(white: 0.75, alpha: 1)
        preview.lineBreakMode = .byTruncatingTail
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: w - 16).isActive = true
        stack.addArrangedSubview(preview)

        let hint = NSTextField(labelWithString: L.t("contacts.hint"))
        hint.font = NSFont.systemFont(ofSize: 10.5)
        hint.textColor = NSColor(white: 0.55, alpha: 1)
        stack.addArrangedSubview(hint)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        let size = root.fittingSize
        panel.setFrame(frame(for: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Below the caret (above it if there is no room), kept on screen; fixed while the list is open.
    private func frame(for size: NSSize) -> NSRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if anchor == nil {
            if let r = CaretLocator.caretRect() {
                anchor = NSPoint(x: r.minX, y: primaryH - r.maxY)
                caretTop = primaryH - r.minY
            } else if let f = CaretLocator.fieldRect() {
                anchor = NSPoint(x: f.minX + 8, y: primaryH - f.maxY)
                caretTop = primaryH - f.minY
            } else {
                let m = NSEvent.mouseLocation
                anchor = NSPoint(x: m.x + 12, y: m.y - 14)
                caretTop = m.y
            }
        }
        let a = anchor!
        let screen = NSScreen.screens.first { $0.frame.contains(a) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = a.x - 6
        var y = a.y - size.height - 4
        if y < screen.minY { y = caretTop + 4 }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
    private var caretTop: CGFloat = 0
}

/// Never takes keyboard focus from the app the user is typing in.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RowButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func highlighted(_ on: Bool) {
        isBordered = false
        alignment = .left
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor : NSColor.clear.cgColor
    }
}

private final class CheckBox: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
