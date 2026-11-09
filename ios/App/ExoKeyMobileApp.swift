import SwiftUI
import Contacts

@main
struct ExoKeyMobileApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Shared with the keyboard through the app group.
enum Shared {
    static let group = "group.com.jandiradmin.exokeymobile"
    static let defaults = UserDefaults(suiteName: group) ?? .standard
    static var contactsURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("contacts.json")
    }
}

struct ContentView: View {
    @State private var text = ""
    @State private var myEmails = Shared.defaults.string(forKey: "myEmails") ?? ""
    @State private var contactsStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Включить клавиатуру") {
                    Text("1. Настройки → Основные → Клавиатура → Клавиатуры")
                    Text("2. Новые клавиатуры → ExoKey, затем ExoKey → Полный доступ")
                    Text("3. Здесь в поле ниже: зажмите 🌐 и выберите ExoKey")
                    Button("Открыть настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section {
                    Button("Подключить контакты") { loadContacts() }
                    if !contactsStatus.isEmpty { Text(contactsStatus).foregroundStyle(.secondary) }
                    TextField("Мои e-mail (через запятую)", text: $myEmails)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: myEmails) { _, v in Shared.defaults.set(v, forKey: "myEmails") }
                } header: {
                    Text("Имена и e-mail")
                } footer: {
                    Text("Имена и адреса остаются на iPhone. Клавиатура подсказывает адрес, когда набираете «имя@» или пишете в поле e-mail.")
                }
                Section("Проверка") {
                    TextField("Печатайте здесь", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("testField")
                }
                Section("Как пользоваться") {
                    Text("Свайп по пробелу — EN ↔ RU")
                    Text("Долгое нажатие: е → ё, ь/х → ъ, цифры → символы, точка → ? , !")
                    Text("Два пробела — точка. Двойное нажатие ⇧ — Caps Lock.")
                    Text("Калькулятор: 200+15%= → 230")
                }
            }
            .navigationTitle("ExoKey")
            .onAppear { refreshStatus() }
        }
    }

    private func refreshStatus() {
        guard let url = Shared.contactsURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SharedContact].self, from: data) else { return }
        contactsStatus = "Контактов: \(list.count), e-mail: \(list.reduce(0) { $0 + $1.e.count })"
    }

    private func loadContacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { ok, _ in
            guard ok else {
                DispatchQueue.main.async { contactsStatus = "Нет доступа: Настройки → ExoKey → Контакты" }
                return
            }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var list: [SharedContact] = []
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let emails = c.emailAddresses.map { String($0.value) }
                if !name.isEmpty || !emails.isEmpty { list.append(SharedContact(n: name, k: c.nickname, e: emails)) }
            }
            if let url = Shared.contactsURL, let data = try? JSONEncoder().encode(list) { try? data.write(to: url) }
            DispatchQueue.main.async { refreshStatus() }
        }
    }
}

struct SharedContact: Codable {
    let n: String      // name
    let k: String      // nickname
    let e: [String]    // e-mails
}
