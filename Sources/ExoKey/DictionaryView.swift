import SwiftUI

final class DictUIState: ObservableObject {
    @Published var kind: EntryKind = .word
    @Published var lang: Lang?
    @Published var search = ""
    @Published var selection = Set<Int64>()
    @Published var editor: EditorModel?
}

final class EditorModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var entry: UserEntry
    @Published var error = ""
    var warned = false
    let original: UserEntry
    let isNew: Bool
    init(_ e: UserEntry, isNew: Bool) { entry = e; original = e; self.isNew = isNew }
}

struct DictionaryView: View {
    @ObservedObject private var store = UserStore.shared
    @ObservedObject private var ui = DictUIState()

    private var rows: [UserEntry] {
        let q = ui.search.lowercased()
        return store.entries
            .filter { $0.kind == ui.kind && (ui.lang == nil || $0.lang == ui.lang) && (q.isEmpty || $0.word.contains(q) || ($0.target ?? "").contains(q)) }
            .sorted { $0.lastUsed > $1.lastUsed }
    }

    private var selected: [UserEntry] { store.entries.filter { ui.selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $ui.kind) {
                    ForEach(EntryKind.allCases) { k in Text(L.t("kind." + k.rawValue)).tag(k) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("", selection: $ui.lang) {
                    Text(L.t("dict.all")).tag(Lang?.none)
                    ForEach(Lang.allCases) { l in Text(L.langName(l)).tag(Lang?.some(l)) }
                }
                .labelsHidden()
                .frame(width: 150)
                TextField(L.t("dict.search"), text: $ui.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            if ui.kind == .exception { Text(L.t("dict.hintException")).font(.caption).foregroundStyle(.secondary) }
            if ui.kind == .rule { Text(L.t("dict.hintRule")).font(.caption).foregroundStyle(.secondary) }
            if ui.kind == .phrase { Text(L.t("dict.hintPhrase")).font(.caption).foregroundStyle(.secondary) }
            if ui.kind == .banned { Text(L.t("dict.hintBanned")).font(.caption).foregroundStyle(.secondary) }

            Table(rows, selection: $ui.selection) {
                TableColumn(L.t("dict.word"), value: \.word)
                TableColumn(L.t("dict.lang")) { Text($0.lang.short) }.width(50)
                TableColumn(L.t("dict.target")) { e in
                    Text(e.target ?? (e.targetLang.map { "→ \($0.short)" } ?? ""))
                }
                TableColumn(L.t("dict.uses")) { Text("\($0.uses)") }.width(50)
                TableColumn(L.t("dict.undos")) { Text("\($0.undos)") }.width(50)
                TableColumn(L.t("dict.source")) { Text(L.t("src." + $0.source.rawValue)) }.width(80)
                TableColumn(L.t("dict.lastUsed")) { Text($0.lastUsed, format: .dateTime.day().month().hour().minute()) }.width(110)
            }
            .overlay { if rows.isEmpty { Text(L.t("dict.empty")).foregroundStyle(.secondary) } }

            HStack {
                Button(L.t("dict.add")) {
                    ui.editor = EditorModel(UserEntry(word: "", lang: ui.lang ?? .ru, kind: ui.kind == .candidate ? .word : ui.kind), isNew: true)
                }
                Button(L.t("dict.edit")) { if let e = selected.first { ui.editor = EditorModel(e, isNew: false) } }
                    .disabled(ui.selection.count != 1)
                Button(L.t("dict.delete")) { selected.forEach(store.delete); ui.selection = [] }
                    .disabled(ui.selection.isEmpty)
                if ui.kind == .candidate {
                    Button(L.t("dict.confirm")) { move(to: .word) }.disabled(ui.selection.isEmpty)
                }
                if ui.kind == .candidate || ui.kind == .word || ui.kind == .rule {
                    Button(L.t("dict.toException")) { move(to: .exception) }.disabled(ui.selection.isEmpty)
                }
                if ui.kind == .phrase {
                    Button(L.t("dict.toBanned")) { move(to: .banned) }.disabled(ui.selection.isEmpty)
                    Button(L.t("ai.clear")) { UserStore.shared.clearPersonalization() }
                }
                Spacer()
                Text("\(rows.count)").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 480)
        .sheet(item: $ui.editor) { m in
            EntryEditor(m: m) { ui.editor = nil }
        }
    }

    private func move(to k: EntryKind) {
        for e in selected {
            store.delete(e)
            var n = e
            n.kind = k
            n.source = .manual
            n.target = nil
            n.targetLang = nil
            n.lastUsed = Date()
            store.upsert(n)
        }
        ui.selection = []
    }
}

struct EntryEditor: View {
    @ObservedObject var m: EditorModel
    let close: () -> Void

    var body: some View {
        Form {
            Picker(L.t("dict.kind"), selection: $m.entry.kind) {
                ForEach([EntryKind.word, .exception, .rule, .phrase, .banned]) { k in Text(L.t("kind." + k.rawValue)).tag(k) }
            }
            TextField(L.t("dict.word"), text: $m.entry.word)
            Picker(L.t("dict.lang"), selection: $m.entry.lang) {
                ForEach(Lang.allCases) { l in Text(L.langName(l)).tag(l) }
            }
            if m.entry.kind == .rule {
                TextField(L.t("dict.target"), text: Binding(get: { m.entry.target ?? "" }, set: { m.entry.target = $0 }))
                Picker("→", selection: Binding(get: { m.entry.targetLang ?? .ru }, set: { m.entry.targetLang = $0 })) {
                    ForEach(Lang.allCases) { l in Text(L.langName(l)).tag(l) }
                }
            }
            if !m.error.isEmpty { Text(m.error).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(L.t("dict.cancel"), action: close)
                Button(L.t("dict.save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func save() {
        let store = UserStore.shared
        var entry = m.entry
        let trimmed = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.word = (entry.kind == .phrase || entry.kind == .banned) ? trimmed.lowercased() : TextNorm.normalize(trimmed, entry.lang)
        guard !entry.word.isEmpty else { return }
        if entry.kind == .rule, entry.targetLang == nil { entry.targetLang = .ru }
        let o = m.original
        let changedKey = m.isNew || entry.word != o.word || entry.lang != o.lang || entry.kind != o.kind
        if changedKey, store.find(entry.kind, entry.lang, entry.word) != nil {
            m.error = L.t("dict.duplicate"); return
        }
        if !m.warned {
            let others = EntryKind.allCases.filter { $0 != entry.kind && $0 != .candidate }
            if let c = others.first(where: { store.find($0, entry.lang, entry.word) != nil }) {
                m.error = L.t("dict.conflict", L.t("kind." + c.rawValue))
                m.warned = true
                return
            }
        }
        if !m.isNew, changedKey { store.delete(o) }
        entry.source = .manual
        entry.lastUsed = Date()
        if let e = store.upsert(entry) { m.error = e; return }
        close()
    }
}
