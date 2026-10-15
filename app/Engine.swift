// Engine of 강의 받아쓰기 v2: sessions, files, settings — talking to the UI with the same JSON
// events as v1 ({"ev": "seg", ...}), so the interface (ui/index.html) is shared.

import AVFoundation
import Foundation

let env = ProcessInfo.processInfo.environment

/// The real home folder (inside Apple's sandbox, NSHomeDirectory() points into the container).
let realHome: URL = {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
    return URL(fileURLWithPath: NSHomeDirectory())
}()

extension String {
    /// File names come back from disk decomposed (NFD); everything the page sees uses precomposed NFC.
    var nfc: String { precomposedStringWithCanonicalMapping }
}

func fmtTime(_ sec: Double) -> String {
    let s = Int(max(0, sec)), h = s / 3600, m = s % 3600 / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%02d:%02d", m, r)
}

let defaultKeywords = ["출석", "시험", "과제", "퀴즈", "키워드", "암호", "비밀번호", "오늘의 단어", "확인 단어",
                       "attendance", "exam", "quiz", "assignment", "keyword", "password"]

/// Korean keywords match inside words and ignore spacing; Latin-script keywords match whole words
/// (+ plurals) — "exam" finds "exams" and "exam은" but not "example". Same rules as the UI.
func keywordRegex(_ words: [String]) -> NSRegularExpression? {
    let parts = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { w -> String in
        let body = w.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s?")
        let latin = w.range(of: "^[A-Za-z0-9 .'-]+$", options: .regularExpression) != nil
        return latin ? "(?<![A-Za-z0-9])\(body)(?:s|es)?(?![A-Za-z0-9])" : body
    }
    return parts.isEmpty ? nil : try? NSRegularExpression(pattern: parts.joined(separator: "|"), options: [.caseInsensitive])
}

struct Settings {
    var keywords: [String]
    var timestamps: Bool
    var slides: Bool                       // collect slides into a PDF (Mac: the lecture window; files: their video)
    var theme: String                      // 설정: "dark" | "light" | "system"
    var accent: String                     // brass | sage | rose | blue | lavender
    var size: String                       // text size: s | m | l | xl
    var icon: String                       // app icon: navy | ivory | brass | charcoal | sage
    var engine: String                     // 설정 › 음성 인식: apple | whisper | qwen3 | parakeet (Mac, once downloaded)
    var language: String                   // 강의 언어 (main screen): one of LectureLanguage.ids — "ko", "en", "ja", "zh-Hans"…
    var uiLanguage: String                 // the app's own language (설정, the start screen's globe): one of uiLanguages
    var pdfLayout: String                  // 슬라이드 PDF: landscape (slide page, then its transcript) | split (two PDFs) | classic
    var cleanCapture: Bool                 // 깔끔하게 담기: the PDF keeps only the slide (not the browser, the player, black borders)
    static func load() -> Settings {
        let d = UserDefaults.standard
        func pick(_ k: String, _ allowed: [String], _ dflt: String) -> String { allowed.contains(d.string(forKey: k) ?? "") ? d.string(forKey: k)! : dflt }
        return Settings(keywords: d.stringArray(forKey: "keywords") ?? defaultKeywords,
                        timestamps: d.object(forKey: "timestamps") as? Bool ?? true,
                        slides: env["LECTURE_SLIDES"].map { $0 == "1" } ?? (d.object(forKey: "slides") as? Bool ?? false),
                        theme: pick("theme", ["dark", "light", "system"], "dark"),
                        accent: pick("accent", ["brass", "sage", "rose", "blue", "lavender"], "brass"),
                        size: pick("size", ["s", "m", "l", "xl"], "m"),
                        icon: pick("icon", appIcons, "navy"),
                        engine: env["LECTURE_ENGINE"] ?? pick("engine", speechEngines, "apple"),
                        language: env["LECTURE_LANGUAGE"] ?? pick("language", LectureLanguage.ids, firstLanguage(d)),
                        uiLanguage: AppLanguage.initial(d),
                        pdfLayout: env["LECTURE_PDF_LAYOUT"] ?? pick("pdfLayout", pdfLayouts, "landscape"),
                        cleanCapture: env["LECTURE_CLEAN_CAPTURE"].map { $0 != "0" } ?? (d.object(forKey: "cleanCapture") as? Bool ?? true))
    }
    /// A lecture language nobody chose yet: 2.5 and earlier started every lecture in Korean, so someone who used them keeps
    /// Korean; a new user starts in the device's own language (English when a lecture can't be in it).
    static func firstLanguage(_ d: UserDefaults) -> String {
        let used = d.object(forKey: "outFolder") != nil || d.object(forKey: "keywords") != nil
            || (env["LECTURE_TEST_NEW_USER"] != "1"                                   // tests: as on a Mac without one
                && FileManager.default.fileExists(atPath: realHome.appendingPathComponent("Downloads/강의기록").path))
        return used ? "ko" : LectureLanguage.deviceDefault
    }
    func save() {
        let d = UserDefaults.standard
        d.set(keywords, forKey: "keywords"); d.set(timestamps, forKey: "timestamps"); d.set(slides, forKey: "slides")
        d.set(theme, forKey: "theme"); d.set(accent, forKey: "accent"); d.set(size, forKey: "size"); d.set(icon, forKey: "icon")
        d.set(engine, forKey: "engine"); d.set(language, forKey: "language")   // uiLanguage: only a choice is kept (AppLanguage.choose)
        d.set(pdfLayout, forKey: "pdfLayout"); d.set(cleanCapture, forKey: "cleanCapture")
    }
    /// What the page needs to show them.
    var event: [String: Any] {
        ["ev": "settings", "keywords": keywords, "timestamps": timestamps, "slides": slides, "theme": theme, "accent": accent,
         "size": size, "icon": icon, "engine": engine, "language": language, "uiLanguage": uiLanguage, "pdfLayout": pdfLayout, "cleanCapture": cleanCapture,
         "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]
    }
}

let pdfLayouts = ["landscape", "split", "classic"]

/// The app's 12 languages (screens, menus, notices, PDFs — the language a lecture is in is its own: LectureLanguage).
let uiLanguages = ["ko", "en", "zh-Hans", "zh-Hant", "ja", "es", "fr", "de", "pt-BR", "it", "vi", "ru"]

/// The app's own language — every message, menu and PDF follows it. Any thread.
final class AppLanguage: @unchecked Sendable {
    private let lock = NSLock()
    private var v = AppLanguage.initial()      // right from the start: menus are built before the engine (and not via
                                               // Settings.load(): that reads the engine list, whose text needs this)
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = AppLanguage.supported(newValue) ?? "en"; lock.unlock() }
    }
    /// A language tag ("zh-TW", "pt-PT", "fr-CA", "en-KR"…) → the app's language for it; nil for one it doesn't speak.
    static func supported(_ tag: String?) -> String? {
        let t = (tag ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
        if t.hasPrefix("yue-hans") { return "zh-Hans" }                                                         // Cantonese in Simplified
        if ["zh-hant", "zh-tw", "zh-hk", "zh-mo", "yue"].contains(where: { t.hasPrefix($0) }) { return "zh-Hant" }   // Cantonese: Traditional
        if t.hasPrefix("zh") { return "zh-Hans" }
        if t.hasPrefix("pt") { return "pt-BR" }
        let p = String(t.split(separator: "-").first ?? "")
        return ["ko", "en", "ja", "es", "fr", "de", "it", "vi", "ru"].contains(p) ? p : nil
    }
    /// Until someone chooses: the Mac's (iPhone's) own language — the first of its preferred languages, and English when
    /// the app doesn't speak that one.
    static var system: String { supported(Locale.preferredLanguages.first) ?? "en" }
    /// The language chosen in the app (설정 › 언어, the start screen's globe), nil until someone chooses.
    static var chosen: String? { uiLanguages.first { $0 == UserDefaults.standard.string(forKey: "uiLanguageChoice") } }
    /// Someone chose: the app keeps this language, and macOS's own words in it — the menu bar's app name, the Open
    /// window, the Edit menu's extras, the About window — follow from its next launch (this app's setting only).
    static func choose(_ v: String) {
        let d = UserDefaults.standard
        d.set(v, forKey: "uiLanguageChoice")
        if d.stringArray(forKey: "AppleLanguages") != [v] { d.set([v], forKey: "AppleLanguages") }
    }
    /// This launch cleared 2.4.0's pin: macOS already read it, so its own words (Edit menu extras, Open panel) are in
    /// the pinned language until the next launch.
    nonisolated(unsafe) static var pinClearedNow = false
    /// The language to start in: the one chosen, otherwise the system's.
    static func initial(_ d: UserDefaults = .standard) -> String {
        if let v = env["LECTURE_UI_LANGUAGE"] { return supported(v) ?? "en" }
        if let v = d.string(forKey: "uiLanguageChoice"), uiLanguages.contains(v) { return v }
        #if os(macOS)
        // 2.4.0 pinned the app to its language at every launch: let the Mac's own language through, once (after that, a
        // language set for this app in System Settings is respected). Only this app's own pin counts — reading the key
        // through UserDefaults would also see the Mac's own list.
        if !d.bool(forKey: "languagePinCleared") {
            let own = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
            if own?["AppleLanguages"] != nil { pinClearedNow = true }
            d.removeObject(forKey: "AppleLanguages")
            d.set(true, forKey: "languagePinCleared")
        }
        #endif
        return system
    }
}
let appLanguage = AppLanguage()

/// The same text in the app's language: L("한국어", "English") — any other language is looked up from the English.
func L(_ ko: String, _ en: String) -> String {
    switch appLanguage.value {
    case "ko": return ko
    case "en": return en
    case let lang: return translations.text(en, lang)
    }
}

/// File names and the headers inside saved files: Korean or English only, so 기록 reads every file in any language.
func LF(_ ko: String, _ en: String) -> String { appLanguage.value == "ko" ? ko : en }

/// A count with its noun in the app's language: "1 slide", "3 slides", "3 слайда", "5 слайдов" (Korean callers write
/// their own).
func nL(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    let lang = appLanguage.value
    if lang != "ko", lang != "en", let forms = translations.pack(lang).plural[one] {
        return (forms[Translations.category(n, lang)] ?? forms["other"] ?? "{n}")
            .replacingOccurrences(of: "{n} ", with: "{n}\u{00A0}").replacingOccurrences(of: " {n}", with: "\u{00A0}{n}")   // stays with its noun
            .replacingOccurrences(of: "{n}", with: "\(n)")
    }
    return "\(n) \(n == 1 ? one : many ?? one + "s")"
}

/// The other languages' words — the page's own packs (ui/i18n/<lang>.js): English → theirs, where "{0}", "{1}"… stand
/// for what the code puts in. Loaded once per language. Any thread.
final class Translations: @unchecked Sendable {
    struct Pack {
        var text: [String: String] = [:]
        var plural: [String: [String: String]] = [:]
        var templates: [(re: NSRegularExpression, order: [Int], key: String)] = []
    }
    private let lock = NSLock()
    private var packs: [String: Pack] = [:]

    func pack(_ lang: String) -> Pack {
        lock.lock(); defer { lock.unlock() }
        if let p = packs[lang] { return p }
        var p = Pack()
        let dirs = [env["LECTURE_DEV_DIR"].map { $0 + "/ui" }, Bundle.main.resourcePath.map { $0 + "/ui" }].compactMap { $0 }
        if let js = dirs.lazy.compactMap({ try? String(contentsOfFile: $0 + "/i18n/\(lang).js", encoding: .utf8) }).first,
           let head = js.range(of: "(window.I18N = window.I18N || {})[\"\(lang)\"] = "), let b = js.lastIndex(of: "}"),
           let a = js[head.upperBound...].firstIndex(of: "{"), a < b,
           let o = try? JSONSerialization.jsonObject(with: Data(js[a...b].utf8)) as? [String: Any] {
            p.text = o["text"] as? [String: String] ?? [:]
            p.plural = o["plural"] as? [String: [String: String]] ?? [:]
            let hole = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
            for k in p.text.keys where k.contains("{0}") {
                let ns = k as NSString
                var pattern = "^", order: [Int] = [], at = 0
                for m in hole.matches(in: k, range: NSRange(location: 0, length: ns.length)) {
                    pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: at, length: m.range.location - at))) + "([\\s\\S]*?)"
                    order.append(Int(ns.substring(with: m.range(at: 1))) ?? 0)
                    at = m.range.location + m.range.length
                }
                pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: at)) + "$"
                if let re = try? NSRegularExpression(pattern: pattern) { p.templates.append((re, order, k)) }
            }
            let literal = { (k: String) in k.replacingOccurrences(of: #"\{\d+\}"#, with: "", options: .regularExpression).count }
            p.templates.sort { literal($0.key) > literal($1.key) }          // the most specific first, as the page does
        } else {
            log("language pack \(lang) missing — English instead")
        }
        packs[lang] = p
        return p
    }

    /// English → `lang`; what fills a "{0}" is translated too when the pack has it. Anything it lacks stays English.
    func text(_ en: String, _ lang: String) -> String {
        let p = pack(lang)
        if let t = p.text[en] { return t }
        let ns = en as NSString
        for t in p.templates {
            guard let m = t.re.firstMatch(in: en, range: NSRange(location: 0, length: ns.length)), let out = p.text[t.key] else { continue }
            var v: [Int: String] = [:]
            for (j, n) in t.order.enumerated() { v[n] = ns.substring(with: m.range(at: j + 1)) }
            var s = out
            for (n, x) in v { s = s.replacingOccurrences(of: "{\(n)}", with: p.text[x] ?? x) }
            return s
        }
        return en
    }

    /// CLDR's plural category of a whole number, for the app's languages.
    static func category(_ n: Int, _ lang: String) -> String {
        switch lang {
        case "ru":
            let a = n % 10, b = n % 100
            return a == 1 && b != 11 ? "one" : (2...4).contains(a) && !(12...14).contains(b) ? "few" : "many"
        case "fr": return n == 0 || n == 1 ? "one" : "other"
        case "pt-BR": return n == 1 ? "one" : "other"            // CLDR says 0 too, but Brazilian UIs write "0 gravações"
        case "zh-Hans", "zh-Hant", "ja", "vi", "ko": return "other"
        default: return n == 1 ? "one" : "other"
        }
    }
}
let translations = Translations()

let appIcons = ["navy", "ivory", "brass", "charcoal", "sage"]

/// The speech engines this build can offer. Apple's is built in; the others (Mac) are optional downloads.
#if WHISPER
let speechEngines = ["apple"] + engineSpecs.map(\.id)
#else
let speechEngines = ["apple"]
#endif

// MARK: - WAV writing (crash-safe) and AAC compression

/// 16-bit mono WAV whose header is patched every few seconds, so a crash never loses audio.
final class WavWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "lecture.wav")
    private var bytes = 0
    private var lastPatch = Date()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.url = url
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WavWriter.header(dataBytes: 0))
    }

    static func header(dataBytes n: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(clamping: v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n)
        return d
    }

    /// A WAV can't describe more than 4 GiB (≈ 37 hours); the recording stops growing there, the transcript doesn't.
    static let maxDataBytes = Int(UInt32.max) - 64

    func write(_ buf: AVAudioPCMBuffer) {
        guard let p = buf.int16ChannelData?[0] else { return }
        let data = Data(bytes: p, count: Int(buf.frameLength) * 2)
        queue.async { [self] in
            guard bytes + data.count <= WavWriter.maxDataBytes else { return }
            try? handle.write(contentsOf: data)
            bytes += data.count
            if Date().timeIntervalSince(lastPatch) > 5 { patch() }
        }
    }

    private func patch() {
        let end = (try? handle.offset()) ?? 0
        try? handle.seek(toOffset: 4); try? handle.write(contentsOf: WavWriter.header(dataBytes: bytes).subdata(in: 4..<8))
        try? handle.seek(toOffset: 40); try? handle.write(contentsOf: WavWriter.header(dataBytes: bytes).subdata(in: 40..<44))
        try? handle.seek(toOffset: end)
        lastPatch = Date()
    }

    /// Returns seconds written.
    func close() -> Double {
        queue.sync { patch(); try? handle.close() }
        return Double(bytes) / 2 / 16000
    }
}

/// Seconds of audio in a file, or nil if it can't be read (e.g. an m4a cut off mid-write).
func audioSeconds(_ url: URL) -> Double? {
    guard let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 else { return nil }
    return Double(f.length) / f.fileFormat.sampleRate
}

/// WAV → AAC .m4a (≈15 MB per hour). The m4a is written under a hidden temporary name, closed and
/// re-read; only a complete one gets the real name, and only then is the WAV deleted.
/// compress()'s temporary file beside the recording: hidden, and ending in .m4a — AVAudioFile picks the container from
/// the name, and from a ".part" name it wrote CAF (files named .m4a that weren't MPEG-4 until 2.3).
func compressPart(_ m4a: URL) -> URL {
    m4a.deletingLastPathComponent().appendingPathComponent(".\(m4a.deletingPathExtension().lastPathComponent).part.m4a")
}

func compress(wav: URL, seconds: Double) async -> URL {
    let fm = FileManager.default
    let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
    let part = compressPart(m4a)
    try? fm.removeItem(at: part)
    do {
        let input = try AVAudioFile(forReading: wav)
        let output = try AVAudioFile(forWriting: part, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16000 * 10)!
        while input.framePosition < input.length {
            try input.read(into: chunk)
            if chunk.frameLength == 0 { break }
            try output.write(from: chunk)
        }
        output.close()
        if let produced = audioSeconds(part), abs(produced - seconds) < 1.0 {
            if fm.fileExists(atPath: m4a.path) { try fm.removeItem(at: m4a) }      // a broken leftover, never a good one
            try fm.moveItem(at: part, to: m4a)
            try? fm.removeItem(at: wav)
            return m4a
        }
        log("compress check failed: \(audioSeconds(part) ?? -1) vs \(seconds)")
    } catch {
        log("compress error: \(error)")
    }
    try? fm.removeItem(at: part)
    return wav
}

// MARK: - Engine

@MainActor
final class Engine {
    let emit: ([String: Any]) -> Void
    private(set) var ready = false
    private var booting = false
    /// 강의 언어: the lecture languages this device's recognizers speak (asked of macOS while booting), and which of them
    /// have their speech models here.
    private(set) var lectureLanguages: [LectureLanguage] = []
    private var downloadMB: [String: Int] = [:]     // what choosing each would download (0: its models are here)
    private var englishKorean = true                // an English lecture runs the Korean model too (englishWithKorean)
    /// Lecture languages whose models are ready this launch (`pretended`: only pretend-downloaded, tests), on their way
    /// (how far, 0–1), or that couldn't be (why).
    private var prepared: Set<String> = []
    private var pretended: Set<String> = []
    private var fetching: [String: Task<Void, Never>] = [:]
    private var fetchProgress: [String: Double] = [:]
    private var fetchErrors: [String: ModelProblem] = [:]
    /// Why a language's model isn't ready, worded in the app's language when shown (it can change meanwhile).
    enum ModelProblem {
        case missing, download, unsupported, koreanUnsupported
        var message: String {
            switch self {
            case .missing: L("이 강의 언어의 음성 인식 모델이 이 기기에 없습니다. ‘다시 시도’를 누르면 내려받습니다.", "The speech model for this lecture language isn't on this device — Try Again downloads it.")
            case .download: L("이 강의 언어의 음성 인식 모델을 내려받지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도하십시오.", "Couldn't download the speech model for this lecture language. Check the internet connection, then try again.")
            case .unsupported: L("이 기기의 음성 인식은 이 강의 언어를 지원하지 않습니다.", "Speech recognition on this device doesn't support this lecture language.")
            case .koreanUnsupported: L("이 기기에서 한국어 음성 인식을 지원하지 않습니다.", "This device doesn't support Korean speech recognition.")
            }
        }
    }
    private var shownState = ""                      // the engine state the page last heard of (sent again only when it changes)
    private var recordingLanguage: String?           // the lecture language of the recording in progress (or being saved)
    private var startWaiting = false                 // a Start waits for its model's reservation: further presses are ignored
    private(set) var session: Session?
    private var saving: [Task<Void, Never>] = []
    private var savingSessions: [Session] = []
    private var recovering: Set<String> = []

    /// Sessions whose files are still being written: recording, or saving after 정지.
    var busyIDs: Set<String> {
        var ids = Set(savingSessions.filter { !$0.done }.map(\.id)).union(recovering)
        if let s = session { ids.insert(s.id) }
        return ids
    }
    var settings = Settings.load()
    var keywords: NSRegularExpression?
    let outDir: URL = env["LECTURE_OUT_DIR"].map { URL(fileURLWithPath: $0) } ?? Engine.defaultOutDir

    /// Mac: 다운로드/강의기록 — or Downloads/Lecture Transcriber for someone who starts in any other language; chosen once, so a
    /// later change of language never moves the library. iPhone/iPad: the app's own folder in the Files app.
    static var defaultOutDir: URL {
        #if os(macOS)
        let downloads = realHome.appendingPathComponent("Downloads"), d = UserDefaults.standard
        if let name = d.string(forKey: "outFolder"), !name.isEmpty { return downloads.appendingPathComponent(name) }
        let korean = FileManager.default.fileExists(atPath: downloads.appendingPathComponent("강의기록").path)
        let name = korean || Settings.load().uiLanguage == "ko" ? "강의기록" : "Lecture Transcriber"
        d.set(name, forKey: "outFolder")
        return downloads.appendingPathComponent(name)
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    #if WHISPER
    let models = engineSpecs.map { ModelStore(spec: $0) }
    func model(_ id: String) -> ModelStore? { models.first { $0.spec.id == id } }
    #endif

    init(emit: @escaping ([String: Any]) -> Void) {
        self.emit = emit
        keywords = keywordRegex(settings.keywords)
        #if WHISPER
        if let m = model(settings.engine), !m.installed { settings.engine = "apple"; settings.save() }   // model gone
        for m in models {
            let id = m.spec.id
            m.onChange = { [weak self] in self?.modelsChanged() }
            m.onReady = { [weak self] in self?.downloaded(id) }
        }
        #endif
    }

    #if WHISPER
    /// Downloaded on purpose: use it — unless it can't write the current lecture's language and another downloaded
    /// engine already does (Parakeet doesn't push Qwen3-ASR aside for a Korean lecture).
    private func downloaded(_ id: String) {
        guard let m = model(id) else { return }
        let name = m.spec.name
        if m.spec.languages.contains(settings.language) { selectEngine(id); return }
        if let current = model(settings.engine), current.state == .ready, current.spec.languages.contains(settings.language) {
            emit(["ev": "notice", "code": "engine_language",
                  "msg": L("\(name) 모델을 내려받았습니다. 영어 강의 전용이라 지금은 \(current.spec.name) 모델을 그대로 사용합니다 — 영어 강의에 사용하려면 설정 › 음성 인식에서 선택하십시오.", "Downloaded the \(name) model. It's for English lectures only, so the \(current.spec.name) model stays in use for now — to use it for English lectures, choose it in Settings › Speech Recognition.")])
            emit(enginesEvent)
            return
        }
        selectEngine(id)
        emit(["ev": "notice", "code": "engine_language", "msg": m.spec.languages == ["en"]
              ? L("\(name) 모델은 영어 강의 전용입니다. 강의 언어를 English로 바꾸면 \(name) 모델로 받아 적습니다.", "The \(name) model is for English lectures only. Switch the lecture language to English to transcribe with the \(name) model.")
              : L("\(name) 모델은 한국어와 영어 강의를 받아 적습니다. 강의 언어를 한국어나 English로 바꾸면 \(name) 모델로 받아 적습니다.", "The \(name) model transcribes Korean and English lectures. Switch the lecture language to Korean or English to transcribe with the \(name) model.")])
    }

    /// A shared file (the voice detector) may have gone with another engine's check.
    private func modelsChanged() {
        models.forEach { $0.refresh() }
        emit(enginesEvent)
    }
    #endif

    /// 설정 › 음성 인식: every engine this app offers and its state. The page draws whatever is listed, so another
    /// platform (a Windows build, say) can offer its own engines through the same events and commands.
    var enginesEvent: [String: Any] {
        var list: [[String: Any]] = [["id": "apple", "name": L("Apple 음성 인식", "Apple Speech Recognition"), "desc": L("기본 · 가볍고 빠르며 macOS에 들어 있습니다", "Default · Light and fast, built into macOS"),
                                      "state": "ready", "bytes": 0]]
        #if WHISPER
        for m in models {                                 // a ready engine's size: what 삭제 frees (the shared detector stays
            var info = m.info                             // while another engine has it)
            if m.state == .ready {
                let shared = Set(models.filter { $0 !== m && $0.state != .absent }.flatMap { $0.spec.files.map(\.name) })
                info["bytes"] = m.spec.files.filter { !shared.contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
            }
            list.append(info)
        }
        #endif
        var current = settings.engine
        #if WHISPER
        if let m = model(current), m.state != .ready { current = "apple" }                   // what a recording would use
        #endif
        return ["ev": "engines", "list": list, "current": current, "busy": session != nil]
    }

    func selectEngine(_ id: String) {
        #if WHISPER
        guard id == "apple" || model(id)?.state == .ready else { return }
        #else
        guard id == "apple" else { return }
        #endif
        if settings.engine != id { log("engine: \(id)") }
        settings.engine = id
        settings.save()
        emit(settings.event)
        emit(enginesEvent)
    }

    func downloadEngine(_ id: String) {
        #if WHISPER
        guard let m = model(id) else { return }
        if let other = models.first(where: { $0 !== m && ($0.downloading || $0.state == .verifying) }) {   // one at a time
            emit(["ev": "notice", "code": "engine_downloading",
                  "msg": L("\(other.spec.name) 모델을 내려받는 중입니다. 끝난 뒤에 내려받을 수 있습니다.", "The \(other.spec.name) model is downloading. You can download this one when it finishes.")])
            return
        }
        m.download()
        #endif
    }

    func cancelEngine(_ id: String) {
        #if WHISPER
        model(id)?.cancel()
        #endif
    }

    func removeEngine(_ id: String) {
        #if WHISPER
        guard let m = model(id) else { return }
        if session?.engineID == id || savingSessions.contains(where: { !$0.done && $0.engineID == id }) {
            emit(["ev": "notice", "code": "engine_busy", "msg": L("지금 \(m.spec.name) 모델로 받아 적는 중입니다. 끝난 뒤에 삭제할 수 있습니다.", "The \(m.spec.name) model is transcribing right now. You can delete it when that's finished.")])
            return
        }
        // the voice detector stays while another engine has it
        let shared = Set(models.filter { $0 !== m && $0.state != .absent }.flatMap { $0.spec.files.map(\.name) })
        m.remove(keeping: shared)
        if settings.engine == id { selectEngine("apple") } else { emit(enginesEvent) }
        #endif
    }

    /// The recognizer for a new session: the chosen engine, or Apple's when the chosen one isn't ready.
    func makeRecognizer(live: Bool) -> (SpeechRecognizer, String) {
        #if WHISPER
        if let m = model(settings.engine) {
            let name = m.spec.name
            if !m.spec.languages.contains(settings.language) {
                emit(["ev": "notice", "code": "engine_language", "msg": sitsOut(m.spec)])
            } else if m.state == .ready {
                let r = WhisperRecognizer(live: live, major: settings.language, spec: m.spec)
                r.onFallback = { [weak m] in m?.recheck() }
                let lang = settings.language                     // the recording's — not one chosen during it
                r.makeApple = { [weak self] in self?.appleRecognizer(lang) ?? Recognizer(main: lang == "en" ? "en" : "ko") }
                return (r, m.spec.id)
            } else {
                emit(["ev": "notice", "code": "engine_missing", "msg": m.downloading || m.state == .verifying
                      ? L("\(name) 모델을 아직 준비하는 중이라 이번에는 Apple 음성 인식으로 받아 적습니다.", "The \(name) model is still getting ready, so Apple Speech Recognition will transcribe this time.")
                      : L("\(name) 모델이 없어서 Apple 음성 인식으로 받아 적습니다. 설정 › 음성 인식에서 내려받을 수 있습니다.", "The \(name) model isn't downloaded, so Apple Speech Recognition will transcribe. You can download it in Settings › Speech Recognition.")])
            }
        }
        #endif
        return (appleRecognizer(), "apple")
    }

    /// Apple's recognizer for the lecture language: Korean and English write each other's quotes (an English lecture with
    /// the Korean model only when `englishKorean`); any other language its own model alone.
    func appleRecognizer(_ language: String? = nil) -> SpeechRecognizer {
        let lang = language ?? settings.language
        if lang == "ko" || (lang == "en" && englishKorean) { return Recognizer(main: lang) }
        guard let l = lectureLanguages.first(where: { $0.id == lang }) else { return Recognizer(main: lang == "en" ? "en" : "ko") }
        log("recognizer: \(l.locale.identifier(.bcp47))\(l.dictation ? " (dictation model)" : "")")
        let r = SoloRecognizer(l)
        r.onMissingModel = { [weak self] in self?.modelMissing(l.id) }
        return r
    }

    /// A recording found its language's model gone (macOS deleted it; it starts fetching it by itself): it counts as
    /// missing again and is fetched — the page hears of the download when the recording ends.
    private func modelMissing(_ id: String) {
        prepared.remove(id)
        Task {
            await refreshDownloads()
            fetch(id)
        }
    }

    #if WHISPER
    /// An engine that doesn't write the lecture's language sits it out: Apple's recognizer writes it instead.
    private func sitsOut(_ spec: EngineSpec) -> String {
        let name = spec.name
        if spec.languages == ["en"] && settings.language == "ko" {
            return L("\(name) 모델은 영어 강의 전용이라 한국어 강의는 Apple 음성 인식으로 받아 적습니다.", "The \(name) model is for English lectures only, so Korean lectures are transcribed with Apple Speech Recognition.")
        }
        return spec.languages == ["en"]
            ? L("\(name) 모델은 영어 강의 전용이라 이 강의 언어는 Apple 음성 인식으로 받아 적습니다.", "The \(name) model is for English lectures only, so Apple Speech Recognition transcribes this lecture language.")
            : L("\(name) 모델은 한국어와 영어 강의만 받아 적으므로 이 강의 언어는 Apple 음성 인식으로 받아 적습니다.", "The \(name) model transcribes Korean and English lectures only, so Apple Speech Recognition transcribes this lecture language.")
    }
    #endif

    /// 강의 언어: the languages the page lists (it names them itself, in the app's language) and which need a download.
    var languagesEvent: [String: Any] {
        ["ev": "languages", "englishKorean": englishKorean, "list": lectureLanguages.map { l -> [String: Any] in
            let mb = prepared.contains(l.id) && !pretended.contains(l.id) ? 0 : downloadMB[l.id] ?? 0
            return ["id": l.id, "installed": mb == 0, "mb": mb, "dictation": l.dictation, "fetching": fetching[l.id] != nil && !prepared.contains(l.id)]
        }]
    }

    /// What each language would download now (models come and go: fetched here or by another app, deleted by macOS).
    private func refreshDownloads() async {
        englishKorean = await LectureLanguage.englishWithKorean()
        downloadMB = await LectureLanguage.downloadMB(lectureLanguages, englishKorean: englishKorean)
        emit(languagesEvent)
    }

    /// What `makeRoom` lets go of last: the two languages at hand on the switch and the one being recorded.
    private var keptLocales: [String] {
        let quick = ["ko", "en"].contains(appLanguage.value) || !lectureLanguages.contains(where: { $0.id == appLanguage.value })
            ? ["ko", "en"] : [appLanguage.value, "en"]
        return Array(Set((quick + [recordingLanguage].compactMap { $0 }).flatMap(locales(of:))))
    }

    /// The recognizer locales a language's recording uses.
    private func locales(of id: String) -> [String] {
        if id == "ko" || (id == "en" && englishKorean) { return ["ko-KR", "en-US"] }
        return lectureLanguages.first { $0.id == id }.map { [$0.locale.identifier(.bcp47)] } ?? []
    }

    /// Gets a lecture language's speech models onto this device — at once when they're here already. Several can be on
    /// their way; the page hears only of the current language's (`emitLanguageState`).
    private func fetch(_ lang: String) {
        guard !prepared.contains(lang), fetching[lang] == nil else { return }
        fetchErrors[lang] = nil
        defer { if (downloadMB[lang] ?? 0) > 0 { emit(languagesEvent) } }     // the list marks it as on its way
        fetching[lang] = Task {
            do {
                let done = try await Recognizer.prepare(language: lang, korean: englishKorean, keep: keptLocales) { fraction in
                    Task { @MainActor in
                        guard self.fetching[lang] != nil else { return }               // a tick after the end
                        self.fetchProgress[lang] = fraction
                        if lang == self.settings.language { self.emitLanguageState() }
                    }
                }
                prepared.insert(lang)
                if done.pretend { pretended.insert(lang) }
                // a language whose model was let go of to make room is fetched again before its next recording
                prepared = prepared.filter { id in id == lang || !locales(of: id).contains(where: done.released.contains) }
            } catch {
                log("lecture language \(lang): \(error)")
                let ns = error as NSError
                fetchErrors[lang] = (error as? EngineError)?.code == "unsupported" ? .unsupported
                    : ns.domain == "LectureScribe" && ns.code == 1 ? .koreanUnsupported : .download
            }
            fetching[lang] = nil
            fetchProgress[lang] = nil
            await refreshDownloads()
            if lang == settings.language { emitLanguageState() }
        }
    }

    /// What the page shows for the current lecture language: ready, its model downloading, or why it couldn't be. Not while
    /// a recording runs: it keeps the language it started with, and the page would take a new state for the engine
    /// restarting (the end of the recording brings it up to date).
    private func emitLanguageState(force: Bool = false) {
        guard ready, !busy else { return }                  // recording or saving: their end brings the page up to date
        let lang = settings.language
        if prepared.contains(lang) || (fetching[lang] != nil && fetchProgress[lang] == nil && downloadMB[lang] == 0) {
            showEngine(readyEvent, force: force)             // its models are here: reserving them takes a moment
        } else if let e = fetchErrors[lang] {
            showEngine(["ev": "engine", "state": "error", "retry": true, "msg": e.message,              // the status line: a short label,
                        "label": L("음성 인식 모델 필요", "Speech model needed")], force: force)     // the notice: all of it
        } else {
            showEngine(downloadingEvent(fetchProgress[lang] ?? 0), force: force)
        }
    }

    private var readyEvent: [String: Any] { ["ev": "engine", "state": "ready", "msg": L("준비됨", "Ready")] }

    private func showEngine(_ ev: [String: Any], force: Bool = false) {
        let key = "\(ev["state"] ?? "")|\(ev["done"] ?? "")|\(ev["msg"] ?? "")"
        guard force || key != shownState else { return }
        shownState = key
        emit(ev)
    }

    private func downloadingEvent(_ fraction: Double) -> [String: Any] {
        ["ev": "engine", "state": "downloading", "done": Int(fraction * 100), "total": 100,
         "label": L("음성 인식 모델 준비 중", "Getting the speech model ready")]
    }

    /// 다시 시도: the engine didn't start, or the lecture language's model didn't download.
    func retry() {
        if ready { fetch(settings.language); emitLanguageState() } else { boot() }
    }

    var busy: Bool { session != nil || !saving.isEmpty }

    /// 슬라이드 PDF turned off while sessions are still being saved: no PDF for them either.
    func dropSavingSlides() { savingSessions.filter { !$0.done }.forEach { $0.dropSlides() } }

    /// The page loaded (or reloaded, e.g. after iOS reclaimed it in the background).
    func pageLoaded() {
        if ready || booting { replay() } else { boot() }
    }

    /// Everything a freshly loaded page needs to show the current state.
    func replay() {
        emit(settings.event)
        emit(enginesEvent)
        if !lectureLanguages.isEmpty { emit(languagesEvent) }
        if !ready { emit(["ev": "engine", "state": "loading", "msg": L("엔진 준비 중", "Getting the engine ready")]); shownState = "" }
        else if busy { showEngine(readyEvent, force: true) }
        else { emitLanguageState(force: true) }
        if let s = session { s.replay() }
        else if let s = savingSessions.first(where: { !$0.done }) {
            emit(["ev": "rec", "state": "finishing", "mode": s.mode == .live ? "live" : "file"])
        }
    }

    func boot() {
        guard !booting, !ready else { return }
        booting = true
        emit(settings.event)
        emit(enginesEvent)
        emit(["ev": "engine", "state": "loading", "msg": L("엔진 준비 중", "Getting the engine ready")])
        shownState = ""
        Task {
            let d = UserDefaults.standard
            let chosenBefore = LectureLanguage.ids.contains(d.string(forKey: "language") ?? "")   // kept from an earlier launch
            if lectureLanguages.isEmpty {
                lectureLanguages = await LectureLanguage.available()
                log("lecture languages: \(lectureLanguages.map { $0.locale.identifier(.bcp47) + ($0.dictation ? "*" : "") }.joined(separator: " "))")
            }
            let started = Date()
            await refreshDownloads()                     // sizes first: the choices below look at them
            log("lecture languages here: \(downloadMB.filter { $0.value == 0 }.keys.sorted().joined(separator: " ")) · English with Korean: \(englishKorean) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            // a language that starts by itself is offered here and small: not macOS's dictation model (about 1.1 GB)
            // unless that is here already
            let small = { (id: String) -> Bool in
                guard let l = self.lectureLanguages.first(where: { $0.id == id }) else { return false }
                return !l.dictation || self.downloadMB[id] == 0
            }
            if !lectureLanguages.isEmpty, !lectureLanguages.contains(where: { $0.id == settings.language }),
               let other = [LectureLanguage.deviceDefault, "en", "ko"].first(where: small) ?? lectureLanguages.first?.id {
                log("lecture language \(settings.language) isn't on this device: \(other)")      // chosen on a newer macOS, or broken
                settings.language = other
                settings.save()
                emit(settings.event)
            }
            // a new user starts small: when their device's language needs the dictation model, in English — they choose
            // that language themselves, with its size shown
            if env["LECTURE_LANGUAGE"] == nil, !chosenBefore, !lectureLanguages.isEmpty, !small(settings.language) {
                log("lecture language \(settings.language): dictation model, not here — a new user starts in English")
                settings.language = "en"
                emit(settings.event)
            }
            // the first launch's lecture language stays this user's — a later launch would otherwise read the folder 2.6
            // itself just made (`outFolder`) as a sign of 2.5 and start in Korean (Settings.firstLanguage)
            if env["LECTURE_LANGUAGE"] == nil, !chosenBefore { d.set(settings.language, forKey: "language") }
            ready = true
            booting = false
            if chosenBefore, env["LECTURE_LANGUAGE"] == nil, (downloadMB[settings.language] ?? 0) > 0 {
                // the kept language's model isn't here (macOS deleted it, or its download never finished): ask first —
                // 다시 시도 fetches it (a first launch's own language downloads as it always did, the page showing how far)
                log("lecture language \(settings.language): its model isn't here — asking before downloading it")
                fetchErrors[settings.language] = .missing
            } else {
                fetch(settings.language)
            }
            emitLanguageState()
            log("engine ready")
            #if WHISPER
            for m in models { m.warmUpIfUpdated(selected: settings.engine == m.spec.id) }
            #endif
            let dir = self.outDir
            Task.detached {
                recoverSlides()
                await recoverOrphans(in: dir) { id, busy in
                    await MainActor.run {
                        if busy { self.recovering.insert(id) } else { self.recovering.remove(id); self.emit(["ev": "recovered", "id": id]) }
                    }
                }
            }
            if env["LECTURE_AUTOSTART"] == "1" {
                start(.live)
                if let s = Double(env["LECTURE_AUTOSTOP"] ?? "") {
                    Task { try? await Task.sleep(for: .seconds(s)); self.stop() }
                }
            }
        }
    }

    /// iPhone: the document picker's copy of a file we won't use.
    private func discardIfTemp(_ file: URL?) {
        guard let f = file, f.resolvingSymlinksInPath().path
            .hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) else { return }
        try? FileManager.default.removeItem(at: f)
    }

    func start(_ mode: Session.Mode, file: URL? = nil) {
        guard session == nil else {
            if mode == .file { emit(["ev": "notice", "code": "busy_recording", "msg": L("지금 받아 적는 중입니다. 끝난 뒤에 다시 시도하십시오.", "Transcription is already in progress. Try again when it's finished.")]) }
            discardIfTemp(file)
            return
        }
        guard savingSessions.allSatisfy({ $0.done }) else {
            emit(["ev": "notice", "code": "busy_saving", "msg": L("저장이 끝나면 다시 시작할 수 있습니다.", "You can start again once saving has finished.")])
            discardIfTemp(file)
            return
        }
        guard ready else {
            emit(["ev": "notice", "code": "not_ready", "msg": L("엔진이 아직 준비 중입니다. 준비되면 다시 시도하십시오.", "The engine is still getting ready. Try again once it's ready.")])
            discardIfTemp(file)
            return
        }
        let lang = settings.language
        guard prepared.contains(lang) else {                           // a lecture language chosen a moment ago
            if let f = fetching[lang], fetchProgress[lang] == nil, downloadMB[lang] == 0 {   // its models are here: only being
                guard !startWaiting else {                                                  // reserved, a moment
                    emit(["ev": "notice", "code": "not_ready", "msg": L("이 강의 언어의 음성 인식 모델을 아직 준비하는 중입니다. 준비되면 시작할 수 있습니다.", "The speech model for this lecture language is still getting ready. You can start once it's ready.")])
                    discardIfTemp(file); return
                }
                startWaiting = true
                Task { await f.value; self.startWaiting = false; self.start(mode, file: file) }
                return
            }
            emit(["ev": "notice", "code": "not_ready", "msg": fetchErrors[lang]?.message
                  ?? L("이 강의 언어의 음성 인식 모델을 아직 준비하는 중입니다. 준비되면 시작할 수 있습니다.", "The speech model for this lecture language is still getting ready. You can start once it's ready.")])
            emitLanguageState()
            discardIfTemp(file)
            return
        }
        guard !pretended.contains(lang) else {                         // tests: macOS would fetch the real model by itself
            log("test: \(lang) was only pretend-downloaded (LECTURE_TEST_FAKE_DOWNLOAD) — not recording in it")
            emit(["ev": "notice", "code": "not_ready", "msg": "Test: \(lang) was only pretend-downloaded — no recording in it."])
            discardIfTemp(file)
            return
        }
        do {
            let s = try Session(engine: self, mode: mode, file: file)
            session = s
            recordingLanguage = lang
            emit(enginesEvent)
            Task {
                do { try await s.start() } catch {
                    guard session === s else { log("late start failure ignored: \(error)"); return }   // that session already ended
                    log("session start failed: \(error)")
                    if mode == .file {
                        let ce = error as? CaptureError
                        emit(["ev": "notice", "code": "file_error", "msg": ce?.status == -3
                              ? L("파일을 여는 데 너무 오래 걸립니다. iCloud나 네트워크에 있는 파일이면 먼저 이 기기에 내려받은 뒤 다시 시도하십시오.", "Opening the file is taking too long. If it's in iCloud or on a network, download it to this device first, then try again.")
                              : ce?.step == "no audio track" ? L("이 파일에는 소리가 없어서 받아 적을 수 없습니다.", "This file has no sound, so it can't be transcribed.")
                              : L("이 파일에서 소리를 읽을 수 없습니다. 녹음이나 영상 파일인지 확인하십시오.", "Can't read any sound from this file. Make sure it's an audio or video file.")])
                    } else {
                        emit(["ev": "notice", "code": "tap_error", "msg": L("소리를 가져오지 못했습니다.", "Couldn't capture the sound.")])
                    }
                    stop()
                }
            }
        } catch {
            emit(["ev": "notice", "code": "file_missing", "msg": L("파일을 만들거나 열 수 없습니다.", "Can't create or open the file.")])
            discardIfTemp(file)
        }
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        emit(enginesEvent)
        savingSessions.append(s)
        let t = Task { await s.finish() }
        saving.append(t)
        Task {
            await t.value
            saving.removeAll { $0 == t }
            savingSessions.removeAll { $0 === s }
            if session == nil && saving.isEmpty { recordingLanguage = nil }
            emitLanguageState()                           // a lecture language chosen during the recording may be downloading
        }
    }

    /// Quit: stop and wait for every save in progress.
    func shutdown() async {
        stop()
        for t in saving { await t.value }
    }

    func updateSettings(_ msg: [String: Any]) {
        if let words = msg["keywords"] as? [String] {
            settings.keywords = Array(words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(60))
            keywords = keywordRegex(settings.keywords)
        }
        if let ts = msg["timestamps"] as? Bool { settings.timestamps = ts }
        if let sl = msg["slides"] as? Bool { settings.slides = sl }
        if let v = msg["theme"] as? String, ["dark", "light", "system"].contains(v) { settings.theme = v }
        if let v = msg["accent"] as? String, ["brass", "sage", "rose", "blue", "lavender"].contains(v) { settings.accent = v }
        if let v = msg["size"] as? String, ["s", "m", "l", "xl"].contains(v) { settings.size = v }
        if let v = msg["icon"] as? String, appIcons.contains(v) { settings.icon = v }
        if let v = msg["pdfLayout"] as? String, pdfLayouts.contains(v) { settings.pdfLayout = v }
        if let v = msg["cleanCapture"] as? Bool { settings.cleanCapture = v }
        if let v = msg["uiLanguage"] as? String, uiLanguages.contains(v) { settings.uiLanguage = v; appLanguage.value = v; AppLanguage.choose(v) }
        if let v = msg["language"] as? String, v != settings.language,
           lectureLanguages.isEmpty ? LectureLanguage.ids.contains(v) : lectureLanguages.contains(where: { $0.id == v }) {
            settings.language = v
            #if WHISPER
            if let m = model(settings.engine), m.state == .ready, !m.spec.languages.contains(v) {   // Parakeet: English only
                emit(["ev": "notice", "code": "engine_language", "msg": sitsOut(m.spec)])
            }
            #endif
            if ready {                                    // booting: the boot gets the language it ends with
                fetch(v)
                emitLanguageState()
            }
        }
        settings.save()
        emit(settings.event)
    }
}

/// Waits for a task, but no longer than `seconds` (the task keeps running if it's slower).
func waitBriefly(for task: Task<Void, Error>, seconds: Double) async {
    final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    }
    let once = Once()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        Task { _ = try? await task.value; once.run { c.resume() } }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.run { c.resume() } }
    }
}

/// Hands an audio source to the thread that starts it (sources do their own locking).
/// How far into a video its slides are read (중지 part-way: up to what was transcribed). Any thread.
private final class SlideLimit: @unchecked Sendable {
    private let lock = NSLock(); private var v = Double.infinity
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

private final class SourceBox: @unchecked Sendable {
    let source: AudioSource
    init(_ s: AudioSource) { source = s }
}

/// 일시정지 for the audio thread: while paused the sound is let go. The first buffer after pausing becomes a short
/// silence instead, so the sentence before the break ends there — the recording gets the same silence and stays in
/// step with the transcript's times.
private final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false, gap = false
    func set(_ on: Bool) { lock.lock(); paused = on; if on { gap = true }; lock.unlock() }
    /// Audio thread: (drop this buffer, put the silence in first).
    func take() -> (drop: Bool, gap: Bool) {
        lock.lock(); defer { lock.unlock() }
        let g = gap
        gap = false
        return (paused, g)
    }
}

/// Quiet audio in the sources' format (16 kHz mono Int16).
func silence(seconds: Double) -> AVAudioPCMBuffer? {
    let n = AVAudioFrameCount(seconds * sampleRate)
    guard let b = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: n), let p = b.int16ChannelData?[0] else { return nil }
    b.frameLength = n
    p.update(repeating: 0, count: Int(n))
    return b
}

// MARK: - Session

private let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
private let weekdaysEN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

@MainActor
final class Session {
    enum Mode { case live, file }

    let mode: Mode
    unowned let engine: Engine
    let txtURL: URL
    let header: String
    var id: String { txtURL.deletingPathExtension().lastPathComponent.nfc }
    /// Set just before "saved": the files are final from here on.
    private(set) var done = false
    private let wav: WavWriter?
    private let fileURL: URL?
    private var source: AudioSource?
    private var startTask: Task<Void, Error>?
    private let recognizer: SpeechRecognizer
    /// Which engine transcribes this session ("apple", or a downloaded one's id).
    let engineID: String
    private var slides: SlideCollector?
    private var slideTask: Task<Void, Never>?
    private var slideProgress: Double?
    private let slideLimit = SlideLimit()
    private var reachedEnd = false
    private var lines: [Int: Line] = [:]
    private var written: Set<Int> = []
    private var handle: FileHandle?
    private let stats = Stats()
    private var watchdog: Timer?
    private var stopping = false
    private var closed = false
    private var duration: Double = 0
    private let started = Date()
    private let gate = PauseGate()
    /// 일시정지 (live recordings): nothing is recognized or recorded until 계속.
    private(set) var paused = false
    private var pausedSince: Date?
    private var pausedTotal: Double = 0

    /// Audio-thread counters.
    final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        private var _samples = 0, _nonzero = false, _last = Date.distantPast, _peak: Float = 0, _levelAt = Date()
        func add(_ buf: AVAudioPCMBuffer) -> Float? {
            guard let p = buf.int16ChannelData?[0] else { return nil }
            let n = Int(buf.frameLength)
            var sum: Float = 0, any = false
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v; if p[i] != 0 { any = true } }
            lock.lock(); defer { lock.unlock() }
            _samples += n; _last = Date(); if any { _nonzero = true }
            _peak = max(_peak, (sum / Float(max(n, 1))).squareRoot())
            guard Date().timeIntervalSince(_levelAt) >= 0.1 else { return nil }
            let level = _peak; _peak = 0; _levelAt = Date()
            return level
        }
        var samples: Int { lock.lock(); defer { lock.unlock() }; return _samples }
        var nonzero: Bool { lock.lock(); defer { lock.unlock() }; return _nonzero }
        var last: Date { lock.lock(); defer { lock.unlock() }; return _last }
    }

    init(engine: Engine, mode: Mode, file: URL?) throws {
        self.engine = engine
        self.mode = mode
        self.fileURL = file
        (recognizer, engineID) = engine.makeRecognizer(live: mode == .live)
        try FileManager.default.createDirectory(at: engine.outDir, withIntermediateDirectories: true)
        let now = Date(), cal = Calendar(identifier: .gregorian), c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let stamp = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let title = mode == .live ? LF(String(format: "%@ %02d시%02d분 강의", stamp, c.hour!, c.minute!), String(format: "%@ %02d.%02d Lecture", stamp, c.hour!, c.minute!))
                                  : "\(file!.deletingPathExtension().lastPathComponent) \(LF("받아쓰기", "transcript"))"
        txtURL = Session.unique(engine.outDir.appendingPathComponent("\(title).txt"))
        header = mode == .live
            ? LF(String(format: "강의 녹취 · %@ (%@) %02d:%02d 시작", stamp, weekdays[c.weekday! - 1], c.hour!, c.minute!),
                String(format: "Lecture transcript · %@ (%@) %02d:%02d", stamp, weekdaysEN[c.weekday! - 1], c.hour!, c.minute!))
            : LF("파일 받아쓰기 · \(file!.lastPathComponent) · \(stamp)", "File transcription · \(file!.lastPathComponent) · \(stamp)")
        wav = try WavWriter(url: txtURL.deletingPathExtension().appendingPathExtension("wav"))   // files too: every session keeps its audio
        FileManager.default.createFile(atPath: txtURL.path, contents: (header + "\n\n").data(using: .utf8))
        handle = try FileHandle(forWritingTo: txtURL)
        _ = try? handle?.seekToEnd()
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        func taken(_ u: URL) -> Bool { ["txt", "wav", "m4a", "pdf"].contains { fm.fileExists(atPath: u.deletingPathExtension().appendingPathExtension($0).path) } }
        if !taken(url) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        for i in 2... {
            let u = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(i)).txt")
            if !taken(u) { return u }
        }
        return url
    }

    func start() async throws {
        recognizer.onLine = { [weak self] in self?.handle($0) }
        recognizer.onError = { [weak self] e in
            log("recognizer error: \(e)")
            self?.engine.emit(["ev": "notice", "code": (e as? EngineError)?.code ?? "recognizer",
                               "msg": (e as? EngineError)?.message ?? L("음성 인식이 잠시 멈췄습니다. 녹음은 계속됩니다.", "Speech recognition stopped for a moment. Recording continues.")])
        }
        try await recognizer.start()
        if stopping { return }                       // 정지 already pressed: don't open the microphone/tap at all
        let src: AudioSource
        var fileSource: FileAudioSource?
        if mode == .file, let f = fileURL {
            let fs = FileAudioSource(url: f)
            fileSource = fs
            src = fs
        } else if let fake = env["LECTURE_FAKE_INPUT"] {          // tests: a file played like live audio
            src = FileAudioSource(url: URL(fileURLWithPath: fake), realtime: true)
        } else {
            #if os(macOS)
            src = SystemAudioSource()
            #else
            src = MicAudioSource()
            #endif
        }
        source = src
        src.onProblem = { [weak self] code, msg in
            DispatchQueue.main.async { self?.engine.emit(["ev": "notice", "code": code, "msg": msg]) }
        }
        let rec = recognizer, stats = stats, wav = wav, mode = mode, gate = gate
        src.onBuffer = { [weak self] buf in                       // hooked up before any audio can flow
            guard let buf else {                                    // the file ended: stop this session — never a newer one
                if mode == .file {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.reachedEnd = true } }
                    DispatchQueue.main.async { MainActor.assumeIsolated { if let self, self.engine.session === self { self.engine.stop() } } }
                }
                return
            }
            let (drop, gap) = gate.take()
            if gap, let quiet = silence(seconds: 1.5) { rec.push(quiet); wav?.write(quiet); _ = stats.add(quiet) }
            if drop { return }
            rec.push(buf)
            wav?.write(buf)
            if let level = stats.add(buf) {
                let db = 20 * log10(Double(level) + 1e-9)
                let v = max(0, min(1, (db + 60) / 60))
                DispatchQueue.main.async { self?.tick(level: v) }
            }
        }
        // The UI shows "recording" (and the no-sound watchdog runs) even while the start below waits.
        engine.emit(["ev": "rec", "state": "recording", "mode": mode == .live ? "live" : "file",
                     "started": Date().timeIntervalSince1970, "txt": txtURL.path,
                     "title": txtURL.deletingPathExtension().lastPathComponent, "header": header])
        if mode == .live {
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        // Starting can block (macOS's system-audio permission prompt, probing a file): never on the main thread.
        let box = SourceBox(src)
        let t = Task<Void, Error> {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try box.source.start(); c.resume() } catch { c.resume(throwing: error) }
                }
            }
        }
        startTask = t
        try await t.value
        guard !stopping else { return }                       // 정지 came while starting
        if let fs = fileSource { duration = fs.duration }
        if mode == .file, engine.settings.slides, let f = fileURL, !(await VideoSlides.hasVideo(f)) {
            engine.emit(["ev": "notice", "code": "slides_note", "msg": L("소리만 있는 파일이라 슬라이드 PDF는 만들지 않습니다.", "This file has audio only, so no Slide PDF will be made.")])
        }
        if mode == .file, engine.settings.slides, let f = fileURL, await VideoSlides.hasVideo(f), !stopping {   // slides from the video
            let c = try SlideCollector(settle: 1, transcript: txtURL)     // one frame a second: two alike
            slides = c
            slideProgress = 0
            c.onCount = { [weak self] n in DispatchQueue.main.async { MainActor.assumeIsolated { self?.engine.emit(["ev": "slides", "count": n]) } } }
            c.onPreview = previewSender()
            let limit = slideLimit
            slideTask = Task.detached(priority: .utility) {
                await VideoSlides.extract(f, into: c, until: { limit.value }) { p in
                    DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.slidesAdvanced(p) } }
                }
            }
        }
        log("capture started (\(mode == .live ? "live" : "file"), \(engineID))")
    }

    /// Re-sends this session to a page that was reloaded mid-recording.
    func replay() {
        engine.emit(["ev": "rec", "state": stopping ? "finishing" : "recording", "mode": mode == .live ? "live" : "file",
                     "started": started.timeIntervalSince1970, "txt": txtURL.path, "title": id, "header": header, "replay": true])
        for l in lines.values.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            engine.emit(["ev": "seg", "id": l.id, "t": (l.start * 100).rounded() / 100, "text": l.text, "final": l.final])
        }
        if paused || pausedTotal > 0 { emitPaused() }
    }

    /// 일시정지 / 계속 (live recordings only). The page's clock leaves the paused time out, like the recording does.
    func setPaused(_ on: Bool) {
        guard mode == .live, !stopping, on != paused else { return }
        paused = on
        gate.set(on)
        #if os(macOS)
        (source as? SystemAudioSource)?.setUserPaused(on)
        #endif
        if on { pausedSince = Date() } else if let s = pausedSince { pausedTotal += Date().timeIntervalSince(s); pausedSince = nil }
        emitPaused()
        log(on ? "paused" : "resumed")
    }

    private func emitPaused() {
        engine.emit(["ev": "paused", "on": paused, "total": (pausedTotal * 10).rounded() / 10,
                     "since": pausedSince?.timeIntervalSince1970 ?? 0])
    }

    private func tick(level v: Double) {
        guard !closed else { return }
        engine.emit(["ev": "level", "v": (v * 1000).rounded() / 1000])
        if mode == .file, duration > 0 {
            let audio = min(1, Double(stats.samples) / 16000 / duration)
            engine.emit(["ev": "progress", "done": min(audio, slideProgress ?? 1)])
        }
    }

    private func slidesAdvanced(_ p: Double) {
        slideProgress = p
        if stopping, !closed { engine.emit(["ev": "progress", "slides": (p * 100).rounded() / 100]) }
    }

    /// 슬라이드 PDF turned off mid-session: stop collecting and throw away what was collected.
    func dropSlides() {
        slideTask?.cancel()
        slides?.discard()
        slides = nil
        slideProgress = nil
    }

    /// The live preview for the page: the frame (JPEG), the lecturer's camera if one was found, and the part 깔끔하게 담기
    /// keeps once it is clear (both 0–1, top-left).
    private func previewSender() -> @Sendable (String, CGRect?, CGRect?) -> Void {
        { [weak self] jpeg, cam, clean in
            func box(_ r: CGRect?) -> Any { r.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] } ?? NSNull() }
            let camera = box(cam), area = box(clean)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.engine.emit(["ev": "slidePreview", "img": "data:image/jpeg;base64," + jpeg, "camera": camera, "clean": area])
            } }
        }
    }

    /// A frame of the lecture window (Mac). Slides are found as they appear.
    func addSlideFrame(_ image: CGImage) {
        guard mode == .live, !stopping, !paused, engine.settings.slides else { return }   // paused: the window may show anything
        if slides == nil {
            slides = try? SlideCollector(settle: 1.5, transcript: txtURL)
            slides?.onCount = { [weak self] n in DispatchQueue.main.async { MainActor.assumeIsolated { self?.engine.emit(["ev": "slides", "count": n]) } } }
            slides?.onPreview = previewSender()
        }
        slides?.add(image, at: Double(stats.samples) / 16000)     // audio time, like the transcript: a paused video can't shift it
    }

    private var notified = false
    private func check() {
        let elapsed = Date().timeIntervalSince(started) - pausedTotal - (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
        if paused || Date().timeIntervalSince(stats.last) > 0.6 { engine.emit(["ev": "level", "v": 0]) }
        guard !notified, !paused else { return }
        if stats.samples == 0 && elapsed > 20 {
            notified = true
            engine.emit(["ev": "notice", "code": "no_input", "msg": L("아직 소리가 들어오지 않습니다.", "No sound is coming in yet.")])
        } else if stats.samples > 0 && !stats.nonzero && elapsed > 20 {
            notified = true
            engine.emit(["ev": "notice", "code": "no_audio", "msg": L("20초째 소리가 들어오지 않습니다.", "No sound for 20 seconds.")])
        }
    }

    private func handle(_ line: Line) {
        guard !closed, !(stopping && !line.final) else { return }
        lines[line.id] = line
        if line.final, !line.text.isEmpty, !written.contains(line.id) {   // first version → file now
            written.insert(line.id)
            try? handle?.write(contentsOf: "[\(fmtTime(line.start))] \(line.text)\n".data(using: .utf8)!)
        }
        engine.emit(["ev": "seg", "id": line.id, "t": (line.start * 100).rounded() / 100, "text": line.text, "final": line.final])
    }

    func finish() async {
        stopping = true
        engine.emit(["ev": "rec", "state": "finishing", "mode": mode == .live ? "live" : "file"])
        watchdog?.invalidate()
        source?.stop()
        if let t = startTask {               // 정지 during start-up: let the start finish (≤ 5 s), then stop for sure
            await waitBriefly(for: t, seconds: 5)
            source?.stop()                   // a start that ends later sees the stop and does nothing
        }
        if let t = slideTask {               // a file's slides: read the video to the end — or, after 중지, as far as was transcribed
            if !reachedEnd { slideLimit.value = Double(stats.samples) / 16000 }
            await t.value
        }
        log("session finishing")
        await recognizer.finish()
        closed = true
        // Rewrite the whole transcript in time order (English rescues may have updated lines).
        let finals = lines.values.filter { $0.final && !$0.text.isEmpty }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var text = header + "\n\n" + finals.map { "[\(fmtTime($0.start))] \($0.text)\n" }.joined()
        if let kw = engine.keywords {
            let hits = finals.filter { kw.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
            if !hits.isEmpty { text += "\n── \(LF("중요 문장", "Key Sentences")) ──\n" + hits.map { "[\(fmtTime($0.start))] \($0.text)\n" }.joined() }
        }
        try? handle?.close()
        try? text.data(using: .utf8)?.write(to: txtURL, options: .atomic)
        var audio: URL?
        var seconds = Double(stats.samples) / 16000
        if let wav {
            let secs = wav.close()
            seconds = secs
            if secs > 0 { audio = await compress(wav: wav.url, seconds: secs) } else { try? FileManager.default.removeItem(at: wav.url) }
        }
        var slideCount = 0
        if let c = slides {                  // the slide PDF, next to the transcript (with what was said per slide)
            let lines = finals.map { ($0.start, $0.end, $0.text) }, txt = txtURL, end = seconds, layout = engine.settings.pdfLayout
            let clean = engine.settings.cleanCapture                     // as the switch is when the lecture ends: the whole PDF
            slideCount = await Task.detached(priority: .userInitiated) { c.makePDF(transcript: txt, lines: lines, end: end, layout: layout, clean: clean) }.value
        }
        if finals.isEmpty && seconds < 3 && slideCount == 0 {        // accidental start/stop, unreadable file: no clutter
            try? FileManager.default.removeItem(at: txtURL)
            if let a = audio { try? FileManager.default.removeItem(at: a) }
            done = true
            engine.emit(["ev": "saved", "id": "", "txt": "", "audio": "", "seconds": seconds, "count": 0])
        } else {
            done = true
            engine.emit(["ev": "saved", "id": id, "txt": txtURL.path, "audio": audio?.path ?? "",
                         "seconds": (seconds * 10).rounded() / 10, "count": finals.count, "slides": slideCount])
        }
        if let f = fileURL, f.resolvingSymlinksInPath().path
            .hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path) {   // iPhone: picker's copy
            try? FileManager.default.removeItem(at: f)
        }
        engine.emit(["ev": "rec", "state": "idle", "mode": mode == .live ? "live" : "file"])
        log("session saved: \(finals.count) lines, \(fmtTime(seconds))")
    }
}

// MARK: - Crash recovery

/// Exactly the header WavWriter writes: RIFF/WAVE, 16-byte PCM fmt, mono, 16 kHz, 16-bit, data at 36.
func isOurWAV(_ url: URL) -> Bool {
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? h.close() }
    guard let d = try? h.read(upToCount: 44), d.count == 44 else { return false }
    func u32(_ o: Int) -> UInt32 { d[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
    func u16(_ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    return d[0..<4] == Data("RIFF".utf8) && d[8..<16] == Data("WAVEfmt ".utf8) && u32(16) == 16 && u16(20) == 1
        && u16(22) == 1 && u32(24) == 16000 && u32(28) == 32000 && u16(32) == 2 && u16(34) == 16 && d[36..<40] == Data("data".utf8)
}

/// Is the transcript next to this file one the app wrote?
func hasOurTranscript(_ url: URL) -> Bool {
    let txt = url.deletingPathExtension().appendingPathExtension("txt")
    guard let h = try? FileHandle(forReadingFrom: txt) else { return false }
    defer { try? h.close() }
    guard var d = try? h.read(upToCount: 64) else { return false }
    if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }                  // byte-order mark
    return Library.headerPrefixes.contains { d.starts(with: Data($0.utf8)) }
}

/// Moves a file out of the way, recoverably (Mac: Trash; iPhone: the app's holding folder).
private func setAside(_ url: URL) {
    let fm = FileManager.default
    #if os(macOS)
    if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { return }
    #endif
    let bin = Library.deletedDir.appendingPathComponent(UUID().uuidString)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    try? fm.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
}

/// A crash leaves the half-written WAV behind: repair its header and compress it. Only the app's own
/// files are touched — a WAV with our exact header next to a transcript the app wrote — and only
/// once they've been left alone for a while. Anything else in the folder is never modified.
func recoverOrphans(in dir: URL, busy: (@Sendable (String, Bool) async -> Void)? = nil) async {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    func settled(_ u: URL) -> Bool {
        let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return Date().timeIntervalSince(m) > 15
    }
    for wav in items where wav.pathExtension.lowercased() == "wav" && settled(wav) && isOurWAV(wav) && hasOurTranscript(wav) {
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        for part in [compressPart(m4a), wav.deletingLastPathComponent().appendingPathComponent(".\(m4a.lastPathComponent).part")]
            where fm.fileExists(atPath: part.path) && settled(part) { try? fm.removeItem(at: part) }  // compress() was cut off (also 2.2's name)
        guard let h = try? FileHandle(forUpdating: wav) else { continue }
        var n = min(Int((try? h.seekToEnd()) ?? 44) - 44, WavWriter.maxDataBytes)
        n -= n % 2
        let fixed = WavWriter.header(dataBytes: n)
        try? h.seek(toOffset: 4); try? h.write(contentsOf: fixed.subdata(in: 4..<8))
        try? h.seek(toOffset: 40); try? h.write(contentsOf: fixed.subdata(in: 40..<44))
        try? h.close()
        let seconds = Double(n) / 2 / 16000
        if fm.fileExists(atPath: m4a.path) {                 // saved before, but the WAV stayed
            if let a = audioSeconds(m4a), abs(a - seconds) < 1 { try? fm.removeItem(at: wav); continue }   // our complete copy exists
            setAside(m4a)                                    // a cut-off m4a: out of the way (recoverably), redo it
        }
        let id = wav.deletingPathExtension().lastPathComponent.nfc
        await busy?(id, true)
        let out = await compress(wav: wav, seconds: seconds)
        await busy?(id, false)
        log(out.pathExtension == "m4a" ? "recovered recording from an earlier crash: \(out.lastPathComponent)"
                                       : "could not compress a recording left by a crash: \(wav.lastPathComponent)")
    }
}

// MARK: - Log (no transcript text, no user names)

private let logQueue = DispatchQueue(label: "lecture.log")
let logURL: URL = {
    let dir = env["LECTURE_LOG_DIR"].map { URL(fileURLWithPath: $0) }          // tests running side by side: a log each
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LectureScribe/logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("app.log")
}()

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        .replacingOccurrences(of: realHome.path, with: "~")
    logQueue.async {
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }
}
