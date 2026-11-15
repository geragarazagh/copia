// The keys of the lists (his answers 2026-11-15 ~15:35 to «Spotlight taken apart», clipboard.md): every key in the app is
// settable in Settings, not only the two hot keys («для меня так удобно, а для кого-то нет»). Defaults:
//   Return          Paste: the picks into the app that was in front before the panel opened (Spotlight's clipboard)
//   ⌘Return         Paste as Plain Text; the modifier is a choice: ⇧, ⌘, ⌥, ⌃ or Fn (his pick ⌘, not Spotlight's ⇧)
//   ⌘C              Copy (the panel goes, nothing is pasted)
//   ⌘⌫              Delete (⌫ alone too, while the list has the keys)
//   ⌘Y              Preview (Space too, always, as Quick Look)
//   ⌘1 … ⌘9         Quick Pick: paste the Nth row in sight; while the modifier is held the rows show their numbers
// Fixed, as every Mac list has them: ↑ ↓ (⇧ to stretch), ⌘A, ⌘F, ⌘Z, ⌘, , Esc, Tab, Space, ⌘V (a search with the
// clipboard), ⌘R (Show in Finder). Letters never start a search (his explicit no): ⌘F or Tab does.
// In the big window the same keys act on its selection, but nothing is pasted and the window stays: Paste's key
// copies, Paste as Plain Text's copies plain text.
import AppKit
import Carbon.HIToolbox

/// A modifier that can be added to the Paste key for plain text.
enum PlainMod: String, CaseIterable {
    case shift, command, option, control, fn
    var symbol: String { switch self { case .shift: "⇧"; case .command: "⌘"; case .option: "⌥"; case .control: "⌃"; case .fn: "fn " } }
    var carbon: UInt32 {
        switch self { case .shift: UInt32(shiftKey); case .command: UInt32(cmdKey); case .option: UInt32(optionKey); case .control: UInt32(controlKey); case .fn: 0 }
    }
}

/// The modifier held with 1 … 9 for Quick Pick (⇧ would type the digits' symbols, Fn has no digits of its own).
enum PickMod: String, CaseIterable {
    case command, option, control
    var symbol: String { switch self { case .command: "⌘"; case .option: "⌥"; case .control: "⌃" } }
    var flags: NSEvent.ModifierFlags { switch self { case .command: .command; case .option: .option; case .control: .control } }
}

/// The key codes of 1 … 9 on the number row (ANSI positions: the same physical keys on every layout).
let digitCodes: [UInt16] = [UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5),
                            UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)]

/// The four modifiers a shortcut is made of, in Carbon's bits (as HotKey stores them).
func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.option) { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    if f.contains(.shift) { m |= UInt32(shiftKey) }
    return m
}

extension HotKey {
    static let returnKey = HotKey(code: UInt32(kVK_Return), mods: 0)
    static let copyKey = HotKey(code: UInt32(kVK_ANSI_C), mods: UInt32(cmdKey))
    static let deleteKey = HotKey(code: UInt32(kVK_Delete), mods: UInt32(cmdKey))
    static let previewKey = HotKey(code: UInt32(kVK_ANSI_Y), mods: UInt32(cmdKey))

    /// A key for a list (not a global hot key): any key with or without modifiers, except Esc, which cancels the
    /// recording, and a bare modifier.
    static func local(_ e: NSEvent) -> HotKey? {
        guard e.type == .keyDown, e.keyCode != UInt16(kVK_Escape) else { return nil }
        // The keypad's Enter is Return's twin (Fn-Return on a laptop): kept as Return.
        let code = e.keyCode == UInt16(kVK_ANSI_KeypadEnter) ? UInt16(kVK_Return) : e.keyCode
        return HotKey(code: UInt32(code), mods: carbonMods(e.modifierFlags))
    }

    /// The event is this key: the same key (Enter for Return, ⌦ for ⌫) with exactly these modifiers.
    func matches(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        return sameKey(e.keyCode) && carbonMods(e.modifierFlags) == mods
    }

    func sameKey(_ c: UInt16) -> Bool {
        let c = UInt32(c)
        if c == code { return true }
        if code == UInt32(kVK_Return) && c == UInt32(kVK_ANSI_KeypadEnter) { return true }
        if code == UInt32(kVK_Delete) && c == UInt32(kVK_ForwardDelete) { return true }
        return false
    }
}

/// What a key does in a list.
enum KeyAction: Equatable {
    case paste, pastePlain, copy, delete, preview
    case pick(Int, plain: Bool)   // 0-based: the Nth row in sight
}

/// The settable keys, as stored in the history's settings table (nothing in ~/Library/Preferences).
struct Keys: Equatable {
    var paste = HotKey.returnKey
    var plain = PlainMod.command
    var copy = HotKey.copyKey
    var delete = HotKey.deleteKey
    var preview = HotKey.previewKey
    var pick = PickMod.command

    static let standard = Keys()

    /// The key that pastes plain text: the Paste key with the modifier added, as Settings shows it.
    var plainText: String { plain == .fn ? "fn " + paste.text : HotKey(code: paste.code, mods: paste.mods | plain.carbon).text }
    var pickText: String { "\(pick.symbol)1 – \(pick.symbol)9" }

    /// What the key does, or nil. Quick Pick first (a digit with its modifier), then Paste as Plain Text (more
    /// modifiers than Paste), Paste, Copy, Delete, Preview. ⌫ alone deletes too when Delete is ⌫ with modifiers (⌘⌫ by
    /// default): Finder's Move to Trash is ⌘⌫, and in a list where letters type nothing a bare ⌫ has no other meaning.
    func action(_ e: NSEvent) -> KeyAction? {
        guard e.type == .keyDown else { return nil }
        let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if let n = digitCodes.firstIndex(of: e.keyCode) {
            if f == pick.flags { return .pick(n, plain: false) }
            if plain != .fn, plain.carbon != carbonMods(pick.flags), carbonMods(f) == carbonMods(pick.flags) | plain.carbon {
                return .pick(n, plain: true)
            }
        }
        let m = carbonMods(f)
        if paste.sameKey(e.keyCode) {
            if plain == .fn {
                // Fn-Return on a laptop arrives as the keypad's Enter; an Fn key held with Return carries .function.
                let enter = e.keyCode == UInt16(kVK_ANSI_KeypadEnter) && paste.code == UInt32(kVK_Return)
                if (enter || e.modifierFlags.contains(.function)) && m == paste.mods { return .pastePlain }
            } else if m == paste.mods | plain.carbon && plain.carbon & paste.mods == 0 {
                return .pastePlain
            }
            if m == paste.mods { return .paste }
        }
        if copy.matches(e) { return .copy }
        if delete.matches(e) { return .delete }
        if delete.code == UInt32(kVK_Delete) && delete.sameKey(e.keyCode) && m == 0 { return .delete }
        if preview.matches(e) { return .preview }
        return nil
    }
}

/// A key that edits text in a search field (typing, ⌫, the arrows, ⌘A ⌘C ⌘X ⌘V ⌘Z, ⌃A and the like): while the caret is
/// in the search, it belongs to the field, whatever a setting gives it in the list.
func isTextEditingKey(_ e: NSEvent) -> Bool {
    let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
    let edit: Set<UInt16> = [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete), UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
                             UInt16(kVK_UpArrow), UInt16(kVK_DownArrow), UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_Tab)]
    if f.contains(.command) {
        return ["a", "c", "x", "v", "z"].contains(shortcutKey(e)) || edit.contains(e.keyCode)
    }
    if f.contains(.control) { return true }   // ⌃A ⌃E ⌃K …: the text system's own
    if edit.contains(e.keyCode) { return true }
    let typed = e.characters ?? ""
    return !typed.isEmpty && typed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }
}

/// The keys the lists keep for themselves (not settable), by name, for the clash check.
let fixedKeys: [(String, HotKey)] = [
    ("Space (Preview)", HotKey(code: UInt32(kVK_Space), mods: 0)),
    ("Select All", HotKey(code: UInt32(kVK_ANSI_A), mods: UInt32(cmdKey))),
    ("Search", HotKey(code: UInt32(kVK_ANSI_F), mods: UInt32(cmdKey))),
    ("Undo", HotKey(code: UInt32(kVK_ANSI_Z), mods: UInt32(cmdKey))),
    ("Settings", HotKey(code: UInt32(kVK_ANSI_Comma), mods: UInt32(cmdKey))),
    ("Show in Finder", HotKey(code: UInt32(kVK_ANSI_R), mods: UInt32(cmdKey))),
    ("Paste into Search", HotKey(code: UInt32(kVK_ANSI_V), mods: UInt32(cmdKey))),
    ("Tab", HotKey(code: UInt32(kVK_Tab), mods: 0)),
    ("Up Arrow", HotKey(code: UInt32(kVK_UpArrow), mods: 0)),
    ("Down Arrow", HotKey(code: UInt32(kVK_DownArrow), mods: 0)),
]

/// Every pair of shortcuts that are the same key, as sentences for Settings. A global hot key wins over everything
/// (Carbon takes it before any window), so a list key equal to one never works; two list keys equal to each other: one
/// of them never works. Quick Pick clashes with any key that is its modifier and a digit.
func keyClashes(show: HotKey, queue: HotKey, keys k: Keys) -> [String] {
    var named: [(String, HotKey)] = [(L("Show History"), show), (L("Paste Queue"), queue), (L("Paste"), k.paste)]
    if k.plain != .fn { named.append((L("Paste as Plain Text"), HotKey(code: k.paste.code, mods: k.paste.mods | k.plain.carbon))) }
    named += [(L("Copy"), k.copy), (L("Delete"), k.delete), (L("Preview"), k.preview)]
    named += digitCodes.enumerated().map { (String(format: L("Quick Pick %d"), $0.offset + 1), HotKey(code: UInt32($0.element), mods: carbonMods(k.pick.flags))) }
    named += fixedKeys.map { (L($0.0), $0.1) }
    var out: [String] = []
    var seen = Set<String>()
    for i in named.indices {
        for j in named.indices where j > i && named[i].1 == named[j].1 {
            // Two fixed keys never clash with each other; a fixed key and a Quick Pick only by a setting.
            let fixedFrom = named.count - fixedKeys.count
            if i >= fixedFrom && j >= fixedFrom { continue }
            let line = String(format: L("%@ is set for both %@ and %@."), named[i].1.text, named[i].0, named[j].0)
            if seen.insert(line).inserted { out.append(line) }
        }
    }
    if k.plain.carbon != 0 && k.plain.carbon & k.paste.mods != 0 {
        out.append(String(format: L("Paste as Plain Text needs a modifier that Paste (%@) does not use."), k.paste.text))
    }
    return out
}

extension Store {
    var keys: Keys {
        get {
            var k = Keys.standard
            if let v = setting("key.paste").flatMap(HotKey.init) { k.paste = v }
            if let v = setting("key.plain").flatMap(PlainMod.init) { k.plain = v }
            if let v = setting("key.copy").flatMap(HotKey.init) { k.copy = v }
            if let v = setting("key.delete").flatMap(HotKey.init) { k.delete = v }
            if let v = setting("key.preview").flatMap(HotKey.init) { k.preview = v }
            if let v = setting("key.pick").flatMap(PickMod.init) { k.pick = v }
            return k
        }
        set {
            setSetting("key.paste", newValue.paste.stored)
            setSetting("key.plain", newValue.plain.rawValue)
            setSetting("key.copy", newValue.copy.stored)
            setSetting("key.delete", newValue.delete.stored)
            setSetting("key.preview", newValue.preview.stored)
            setSetting("key.pick", newValue.pick.rawValue)
        }
    }
}

/// The key as a menu shows it beside an item (key equivalent and its modifiers), when a menu can draw it.
func dressMenuKey(_ it: NSMenuItem, _ k: HotKey) {
    let special: [UInt32: String] = [UInt32(kVK_Return): "\r", UInt32(kVK_Delete): "\u{8}", UInt32(kVK_ForwardDelete): "\u{7f}",
                                     UInt32(kVK_Space): " ", UInt32(kVK_Tab): "\t"]
    let ch = special[k.code] ?? keyName(UInt16(k.code)).lowercased()
    guard ch.count == 1 else { return }
    it.keyEquivalent = ch
    var m: NSEvent.ModifierFlags = []
    if k.mods & UInt32(cmdKey) != 0 { m.insert(.command) }
    if k.mods & UInt32(optionKey) != 0 { m.insert(.option) }
    if k.mods & UInt32(controlKey) != 0 { m.insert(.control) }
    if k.mods & UInt32(shiftKey) != 0 { m.insert(.shift) }
    it.keyEquivalentModifierMask = m
}
