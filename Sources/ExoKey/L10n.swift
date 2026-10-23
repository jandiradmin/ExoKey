import Foundation

/// Interface strings: Russian, Ukrainian, English.
enum L {
    static var lang: UILang {
        let s = Settings.shared.uiLang
        if s != .system { return s }
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("uk") { return .uk }
        if pref.hasPrefix("ru") { return .ru }
        return .en
    }

    static func t(_ key: String) -> String {
        guard let e = table[key] else { return key }
        switch lang {
        case .uk: return e.1
        case .en: return e.2
        default: return e.0
        }
    }

    static func t(_ key: String, _ arg: String) -> String { t(key).replacingOccurrences(of: "%@", with: arg) }

    static func langName(_ l: Lang) -> String { t("lang." + l.rawValue) }

    // key: (ru, uk, en)
    static let table: [String: (String, String, String)] = [
        "lang.en": ("Английский", "Англійська", "English"),
        "lang.ru": ("Русский", "Російська", "Russian"),
        "lang.uk": ("Украинский", "Українська", "Ukrainian"),

        "menu.enabled": ("Автоисправление включено", "Автовиправлення увімкнено", "Auto-correction on"),
        "menu.sleep": ("Раскладка не поддерживается — ожидание", "Розкладка не підтримується — очікування", "Layout not supported — sleeping"),
        "menu.dictionary": ("Словарь…", "Словник…", "Dictionary…"),
        "menu.settings": ("Настройки…", "Налаштування…", "Settings…"),
        "menu.autostart": ("Запускать при входе", "Запускати під час входу", "Launch at login"),
        "menu.permissions": ("Выдать разрешения…", "Надати дозволи…", "Grant permissions…"),
        "menu.about": ("О программе ExoKey", "Про ExoKey", "About ExoKey"),
        "menu.quit": ("Завершить ExoKey", "Завершити ExoKey", "Quit ExoKey"),
        "menu.undo": ("Отменить исправление", "Скасувати виправлення", "Undo correction"),
        "menu.convert": ("Исправить последнее слово", "Виправити останнє слово", "Convert last word"),

        "perm.title": ("ExoKey нужны разрешения", "ExoKey потрібні дозволи", "ExoKey needs permissions"),
        "perm.text": ("Чтобы видеть нажатия клавиш и исправлять раскладку, включите ExoKey в Системные настройки → Конфиденциальность и безопасность → «Универсальный доступ» и «Мониторинг ввода». Текст никуда не отправляется и не сохраняется.",
                      "Щоб бачити натискання клавіш і виправляти розкладку, увімкніть ExoKey у Системні параметри → Приватність і безпека → «Доступність» та «Моніторинг введення». Текст нікуди не надсилається і не зберігається.",
                      "To see key presses and fix the layout, enable ExoKey in System Settings → Privacy & Security → Accessibility and Input Monitoring. Text is never sent anywhere or stored."),
        "perm.open": ("Открыть настройки", "Відкрити параметри", "Open Settings"),
        "perm.later": ("Позже", "Пізніше", "Later"),

        "set.title": ("Настройки ExoKey", "Налаштування ExoKey", "ExoKey Settings"),
        "set.general": ("Основные", "Основні", "General"),
        "set.languages": ("Языки для исправления", "Мови для виправлення", "Languages to correct"),
        "set.minLetters": ("Начинать анализ после букв", "Починати аналіз після літер", "Start analysis after letters"),
        "set.learning": ("Обучение на моих действиях", "Навчання на моїх діях", "Learn from my actions"),
        "set.addMode": ("Новые слова в словарь", "Нові слова до словника", "New words to dictionary"),
        "set.addMode.confirm": ("Только после подтверждения", "Лише після підтвердження", "Only after confirmation"),
        "set.addMode.repeated": ("После повторного ввода", "Після повторного введення", "After repeated typing"),
        "set.addMode.immediate": ("Сразу", "Одразу", "Immediately"),
        "set.repeatCount": ("Повторений до добавления", "Повторень до додавання", "Repeats before adding"),
        "set.undos": ("Отмен до исключения", "Скасувань до винятку", "Undos before exception"),
        "set.notifications": ("Уведомления", "Сповіщення", "Notifications"),
        "set.uiLang": ("Язык интерфейса", "Мова інтерфейсу", "Interface language"),
        "set.uiLang.system": ("Как в системе", "Як у системі", "System"),
        "set.uiLang.restart": ("Меню обновится после перезапуска", "Меню оновиться після перезапуску", "Menu updates after restart"),
        "set.autostart": ("Запускать при входе в систему", "Запускати під час входу в систему", "Launch at login"),
        "set.hotkeys": ("Горячие клавиши", "Гарячі клавіші", "Hotkeys"),
        "hk.undo": ("Отменить последнее исправление", "Скасувати останнє виправлення", "Undo last correction"),
        "hk.convert": ("Исправить последнее слово вручную", "Виправити останнє слово вручну", "Convert last word manually"),
        "hk.pause": ("Включить / приостановить", "Увімкнути / призупинити", "Enable / pause"),
        "hk.press": ("Нажмите сочетание…", "Натисніть комбінацію…", "Press shortcut…"),
        "set.excluded": ("Не работать в программах", "Не працювати в програмах", "Don't work in apps"),
        "set.add": ("Добавить…", "Додати…", "Add…"),
        "set.remove": ("Удалить", "Видалити", "Remove"),
        "set.appLayouts": ("Раскладка для программ", "Розкладка для програм", "Layout per app"),
        "set.appLayouts.hint": ("При переходе в программу включается выбранная раскладка", "Під час переходу в програму вмикається вибрана розкладка", "Switching to the app selects this layout"),
        "set.extras": ("Дополнительно", "Додатково", "Extras"),
        "set.calculator": ("Калькулятор: 2+2= → 4", "Калькулятор: 2+2= → 4", "Calculator: 2+2= → 4"),
        "set.learnNames": ("Быстро запоминать имена, названия и сокращения", "Швидко запам’ятовувати імена, назви й скорочення", "Quickly learn names, places and abbreviations"),
        "set.implicitUndo": ("Стёр исправленное слово — считать отменой", "Стер виправлене слово — вважати скасуванням", "Erasing a corrected word counts as undo"),
        "set.skipAllCaps": ("Не исправлять слова ЗАГЛАВНЫМИ буквами", "Не виправляти слова ВЕЛИКИМИ літерами", "Don't correct words in ALL CAPS"),
        "menu.appLayout": ("Раскладка для «%@»", "Розкладка для «%@»", "Layout for “%@”"),
        "menu.appLayout.none": ("Не менять", "Не змінювати", "Don't change"),
        "ai.title": ("Подсказки ИИ (локальная модель)", "Підказки ШІ (локальна модель)", "AI suggestions (local model)"),
        "ai.explain": ("ExoKey может подсказывать продолжение слова и следующее слово по тексту, который вы пишете. Подсказка появляется рядом с курсором, Tab — вставить. Работает полностью на вашем Mac, без интернета: текст никуда не отправляется. Для этого нужно один раз скачать модель (~4,3 ГБ). Пока функция включена, модель занимает около 5 ГБ памяти.",
                       "ExoKey може підказувати закінчення слова й наступне слово за текстом, який ви пишете. Підказка з’являється біля курсора, Tab — вставити. Працює повністю на вашому Mac, без інтернету: текст нікуди не надсилається. Для цього потрібно один раз завантажити модель (~4,3 ГБ). Поки функцію ввімкнено, модель займає близько 5 ГБ пам’яті.",
                       "ExoKey can suggest the end of the word and the next word based on what you are writing. The suggestion appears next to the cursor, Tab inserts it. Runs fully on your Mac, offline: text is never sent anywhere. Requires a one-time model download (~4.3 GB). While enabled, the model uses about 5 GB of memory."),
        "ai.enable": ("Включить подсказки", "Увімкнути підказки", "Enable suggestions"),
        "ai.download": ("Скачать модель (~4,3 ГБ)", "Завантажити модель (~4,3 ГБ)", "Download model (~4.3 GB)"),
        "ai.cancel": ("Остановить загрузку", "Зупинити завантаження", "Cancel download"),
        "ai.remove": ("Удалить модель", "Видалити модель", "Delete model"),
        "ai.state.notInstalled": ("Модель не скачана", "Модель не завантажена", "Model not downloaded"),
        "ai.state.downloading": ("Загрузка…", "Завантаження…", "Downloading…"),
        "ai.state.installed": ("Модель скачана, выключена", "Модель завантажена, вимкнена", "Model downloaded, off"),
        "ai.state.starting": ("Запуск модели…", "Запуск моделі…", "Starting model…"),
        "ai.state.ready": ("Работает", "Працює", "Running"),
        "ai.state.failed": ("Ошибка: %@", "Помилка: %@", "Error: %@"),
        "first.title": ("Добро пожаловать в ExoKey", "Ласкаво просимо до ExoKey", "Welcome to ExoKey"),
        "set.data": ("Данные", "Дані", "Data"),
        "set.resetLearning": ("Сбросить обучение", "Скинути навчання", "Reset learning"),
        "set.deleteAll": ("Удалить все пользовательские данные", "Видалити всі дані користувача", "Delete all user data"),
        "set.deleteAll.confirm": ("Удалить словарь, исключения, правила и обучение?", "Видалити словник, винятки, правила й навчання?", "Delete dictionary, exceptions, rules and learning?"),
        "set.export": ("Экспорт…", "Експорт…", "Export…"),
        "set.import": ("Импорт…", "Імпорт…", "Import…"),
        "set.backup": ("Резервная копия…", "Резервна копія…", "Backup…"),
        "set.restore": ("Восстановить…", "Відновити…", "Restore…"),
        "set.done": ("Готово", "Готово", "Done"),

        "dict.title": ("Словарь ExoKey", "Словник ExoKey", "ExoKey Dictionary"),
        "kind.word": ("Слова", "Слова", "Words"),
        "kind.exception": ("Исключения", "Винятки", "Exceptions"),
        "kind.rule": ("Правила", "Правила", "Rules"),
        "kind.candidate": ("Кандидаты", "Кандидати", "Candidates"),
        "dict.all": ("Все языки", "Усі мови", "All languages"),
        "dict.search": ("Поиск", "Пошук", "Search"),
        "dict.add": ("Добавить", "Додати", "Add"),
        "dict.edit": ("Изменить", "Змінити", "Edit"),
        "dict.delete": ("Удалить", "Видалити", "Delete"),
        "dict.confirm": ("В словарь", "До словника", "To dictionary"),
        "dict.toException": ("В исключения", "До винятків", "To exceptions"),
        "dict.word": ("Слово", "Слово", "Word"),
        "dict.lang": ("Язык", "Мова", "Language"),
        "dict.kind": ("Тип", "Тип", "Type"),
        "dict.target": ("Заменять на", "Замінювати на", "Replace with"),
        "dict.uses": ("Исп.", "Вик.", "Uses"),
        "dict.undos": ("Отмен", "Скас.", "Undos"),
        "dict.lastUsed": ("Последнее", "Останнє", "Last used"),
        "dict.source": ("Источник", "Джерело", "Source"),
        "src.manual": ("вручную", "вручну", "manual"),
        "src.learned": ("обучение", "навчання", "learned"),
        "dict.save": ("Сохранить", "Зберегти", "Save"),
        "dict.cancel": ("Отмена", "Скасувати", "Cancel"),
        "dict.duplicate": ("Такая запись уже есть", "Такий запис уже є", "This entry already exists"),
        "dict.conflict": ("Конфликт: это слово уже есть как %@", "Конфлікт: це слово вже є як %@", "Conflict: this word already exists as %@"),
        "dict.empty": ("Нет записей", "Немає записів", "No entries"),
        "dict.hintException": ("Исключение — текст, который никогда не исправлять (как он набирается в выбранной раскладке).", "Виняток — текст, який ніколи не виправляти (як він набирається у вибраній розкладці).", "Exception — text that is never corrected (as typed in the chosen layout)."),
        "dict.hintRule": ("Правило: набранный текст в раскладке «Язык» заменяется на указанный текст.", "Правило: набраний текст у розкладці «Мова» замінюється на вказаний текст.", "Rule: typed text in the “Language” layout is replaced with the given text."),

        "notif.exception": ("«%@» больше не будет исправляться", "«%@» більше не виправлятиметься", "“%@” will no longer be corrected"),
        "notif.learned": ("Новое слово в словаре: %@", "Нове слово в словнику: %@", "New word in dictionary: %@"),
        "notif.paused": ("ExoKey приостановлен", "ExoKey призупинено", "ExoKey paused"),
        "notif.resumed": ("ExoKey включён", "ExoKey увімкнено", "ExoKey enabled"),
        "notif.undoUnavailable": ("Отмена уже недоступна", "Скасування вже недоступне", "Undo is no longer available"),
    ]
}
