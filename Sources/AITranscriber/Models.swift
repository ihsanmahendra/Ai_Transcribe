import Foundation

struct Segment: Identifiable, Hashable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
    var translation: String?
}

enum ModelOption: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3-v20240930_turbo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largeTurbo: return "Large v3 Turbo"
        }
    }

    var detail: String {
        switch self {
        case .tiny: return "~75 MB · paling cepat, akurasi rendah"
        case .base: return "~140 MB · cepat, cukup akurat"
        case .small: return "~460 MB · seimbang"
        case .largeTurbo: return "~1.6 GB · paling akurat untuk Indonesia/Inggris (disarankan)"
        }
    }
}

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    /// Mode khusus: audio berbahasa Indonesia dan/atau Inggris, termasuk campur-campur (code-switching).
    static let mixedCode = "id-en"

    static let all: [LanguageOption] = [
        LanguageOption(code: mixedCode, name: "Indonesia + Inggris (campuran)"),
        LanguageOption(code: "id", name: "Indonesia"),
        LanguageOption(code: "en", name: "Inggris"),
        LanguageOption(code: "auto", name: "Deteksi otomatis (semua bahasa)"),
        LanguageOption(code: "ms", name: "Melayu"),
        LanguageOption(code: "jw", name: "Jawa"),
        LanguageOption(code: "su", name: "Sunda"),
        LanguageOption(code: "ar", name: "Arab"),
        LanguageOption(code: "ja", name: "Jepang"),
        LanguageOption(code: "ko", name: "Korea"),
        LanguageOption(code: "zh", name: "Mandarin"),
        LanguageOption(code: "es", name: "Spanyol"),
        LanguageOption(code: "fr", name: "Prancis"),
        LanguageOption(code: "de", name: "Jerman"),
        LanguageOption(code: "nl", name: "Belanda"),
    ]

    /// Kode yang sering tertukar dengan bahasa Indonesia oleh Whisper.
    static let indonesianFamily: Set<String> = ["id", "ms", "jw", "su"]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    /// Nama bahasa dalam bahasa Inggris, dipakai di prompt penerjemah.
    static func englishName(for code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}

enum TranslationEngine: String, CaseIterable, Identifiable {
    case claude
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude AI"
        case .apple: return "Apple Translate"
        }
    }

    var detail: String {
        switch self {
        case .claude: return "Paling natural & peka konteks (slang, partikel, formal/santai). Butuh internet & API key."
        case .apple: return "Gratis & offline, tapi per kalimat tanpa memahami konteks."
        }
    }
}

enum TranslationTarget: String, CaseIterable, Identifiable {
    case english = "en"
    case indonesian = "id"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "Inggris"
        case .indonesian: return "Indonesia"
        }
    }

    /// Target kebalikan dari bahasa sumber: Indonesia → Inggris, selain itu → Indonesia.
    static func opposite(of source: String?) -> TranslationTarget {
        guard let source else { return .english }
        return LanguageOption.indonesianFamily.contains(source) ? .english : .indonesian
    }
}

enum ExportContent: String, CaseIterable, Identifiable {
    case original
    case translation
    case bilingual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Teks asli"
        case .translation: return "Terjemahan"
        case .bilingual: return "Dwibahasa"
        }
    }
}

enum TranscriptionStatus: Equatable {
    case idle
    case downloading(model: String, fraction: Double)
    case loadingModel(model: String)
    case detectingLanguage
    case transcribing
    case done(seconds: Double, language: String?)
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .loadingModel, .detectingLanguage, .transcribing: return true
        default: return false
        }
    }
}

enum TranslationStatus: Equatable {
    case idle
    case running(done: Int, total: Int)
    case done
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Flag pembatalan yang aman diakses dari thread latar belakang.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Membatasi frekuensi update UI dari callback yang sangat sering dipanggil
/// (WhisperKit memanggil callback progres untuk setiap token).
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func shouldFire() -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - last >= interval else { return false }
            last = now
            return true
        }
    }
}

func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600, m = (total / 60) % 60, s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}
