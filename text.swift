// Words and numbers shown to people: plural forms, sizes, times. The interface is English only since 0.7 (dev/rules.md,
// section 3, his word 2026-11-15: every word exact; 0.4-0.6 had ru and uk from lang/*.strings). L() stays the one door
// for interface text, so a word can be found and checked in one place; with no table in the bundle it returns the
// English key. macOS's own terms are copied from its English .loctable entries (Search: AppKit Common.loctable; Paste
// from Other Apps: SecurityPrivacyExtension). Numbers and dates still follow the person's region.
import AppKit

/// The bundle that holds the lang tables: the app itself, or the built app when the tests render the panel.
nonisolated(unsafe) var strings = Bundle.main

/// The language the interface is shown in: the system's order of languages (or the one set for this app in System
/// Settings > General > Language & Region > Applications) against en, ru, uk. Fixed for the process, as on macOS a
/// language change takes a relaunch.
let uiLanguage = Bundle.preferredLocalizations(from: strings.localizations, forPreferences: Locale.preferredLanguages).first ?? "en"

/// The table of that language. Looked up by hand rather than through Bundle.localizedString, which for a bundle that
/// is not the running app (the tests' renders) picks the system's first language and ignores -AppleLanguages.
private let table: Bundle? = strings.path(forResource: uiLanguage, ofType: "lproj").flatMap(Bundle.init(path:))

func L(_ s: String) -> String { table?.localizedString(forKey: s, value: s, table: nil) ?? s }

/// Words in the interface language, numbers and dates in the person's region (Finder's way: a Russian interface in
/// Ukraine groups 3 381 with a space, an English one in Germany writes 3.381).
var uiLocale: Locale { Locale(identifier: uiLanguage + (Locale.current.region.map { "_" + $0.identifier } ?? "")) }

/// A count with its noun. The noun's forms are one key, separated by «|»: English one|other, Russian and Ukrainian
/// one|few|many (CLDR rules for whole numbers). L("object|objects") is «объект|объекта|объектов» in ru.
func counted(_ n: Int, _ forms: String) -> String {
    let f = L(forms).components(separatedBy: "|")
    let form: String
    if f.count == 3 {
        let m10 = n % 10, m100 = n % 100
        form = m10 == 1 && m100 != 11 ? f[0] : (2...4).contains(m10) && !(12...14).contains(m100) ? f[1] : f[2]
    } else {
        form = n == 1 ? f[0] : f[f.count - 1]
    }
    return grouped(n) + "\u{00A0}" + form
}

/// 3 381 in ru and uk (a non-breaking space between groups), 3,381 in en: the interface language's own way.
func grouped(_ n: Int) -> String { groupFormat.string(from: NSNumber(value: n)) ?? String(n) }

// The formatters are made once: a new NumberFormatter or DateFormatter per call (every row's time, every count) loads
// ICU's locale data each time, and rows drawn during a clipboard storm spent 0.3-0.7 s of main thread on it (stress
// runs 2026-11-27). Formatting with a formatter that is not changed afterwards is thread-safe.
private nonisolated(unsafe) let groupFormat: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = uiLocale; return f
}()
private nonisolated(unsafe) let sizeFormats: [NumberFormatter] = (0...1).map { u in
    let f = NumberFormatter(); f.locale = uiLocale; f.minimumFractionDigits = 0; f.maximumFractionDigits = u; return f
}
private nonisolated(unsafe) let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = .autoupdatingCurrent   // keeps the person's own 12/24-hour choice
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()
private nonisolated(unsafe) let dayFormats: (near: DateFormatter, thisYear: DateFormatter, before: DateFormatter) = {
    let near = DateFormatter(), thisYear = DateFormatter(), before = DateFormatter()
    for f in [near, thisYear, before] { f.locale = uiLocale }
    near.doesRelativeDateFormatting = true; near.dateStyle = .medium; near.timeStyle = .none
    thisYear.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    before.setLocalizedDateFormatFromTemplate("dMMMMy")
    return (near, thisYear, before)
}()

/// 6,2 МБ / 6.2 MB: decimal units as Finder counts them, in the interface language (Foundation's
/// ByteCountFormatter follows the system locale, so a Russian interface on an English system would read «MB»).
func sizeText(_ bytes: Int) -> String {
    if bytes < 1000 { return counted(bytes, "byte|bytes") }
    var v = Double(bytes) / 1000, u = 0
    let units = ["KB", "MB", "GB", "TB"]
    while v >= 999.95 && u < units.count - 1 { v /= 1000; u += 1 }
    let f = sizeFormats[u == 0 ? 0 : 1]
    return (f.string(from: NSNumber(value: v)) ?? String(v)) + "\u{00A0}" + L(units[u])
}

func timeText(_ d: Date) -> String { timeFormat.string(from: d) }

/// «Сегодня», «Вчера», then the date (with the weekday this year, with the year before): the system's own wording.
func dayText(_ d: Date) -> String {
    let cal = Calendar.current
    let f = cal.isDateInToday(d) || cal.isDateInYesterday(d) ? dayFormats.near
        : cal.isDate(d, equalTo: Date(), toGranularity: .year) ? dayFormats.thisYear : dayFormats.before
    let s = f.string(from: d)
    return s.prefix(1).uppercased() + s.dropFirst()
}
