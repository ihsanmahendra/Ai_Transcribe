import Foundation
import Security

// MARK: - Keychain (penyimpanan API key yang aman)

enum Keychain {
    private static let service = "AITranscriber"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - Claude translator

enum TranslatorError: LocalizedError {
    case missingAPIKey
    case api(status: Int, message: String)
    case refused
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key Claude belum diisi."
        case .api(let status, let message): return "Claude API error \(status): \(message)"
        case .refused: return "Claude menolak menerjemahkan bagian ini."
        case .truncated: return "Jawaban Claude terpotong. Coba lagi."
        case .badResponse: return "Format jawaban Claude tidak dikenali."
        }
    }
}

/// Menerjemahkan segmen transkrip Indonesia ⇄ Inggris lewat Claude Messages API.
/// Segmen dikirim per kelompok beserta beberapa kalimat sebelumnya sebagai konteks,
/// sehingga kata ganti, slang, dan nada bicara diterjemahkan sesuai maksudnya.
struct ClaudeTranslator: Sendable {
    let apiKey: String
    var model = "claude-opus-5-5"
    var chunkSize = 40
    var contextSize = 8
    var maxConcurrent = 4

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You are an expert Indonesian–English subtitle translator who is a native speaker of both \
    languages. You translate speech transcripts produced by automatic speech recognition (ASR).

    Translate each numbered segment into the target language so it reads like natural speech \
    a native speaker would actually say, not a word-for-word translation.

    Be sensitive to:
    - Register and tone. Indonesian distinguishes formal speech (saya, Anda, Bapak/Ibu) from casual \
    speech (aku/kamu, gue/lo, slang such as "anjir", "gokil", "mager", "baper", "wkwk"). Mirror the \
    speaker's level of formality in the target language. When translating into Indonesian, pick the \
    register that matches the English speaker's tone (casual English → casual Indonesian, \
    professional English → baku but natural Indonesian).
    - Discourse particles (sih, dong, kok, deh, lho, kan, ya, nih, tuh, mah, kayak). Convey their \
    nuance through English phrasing or tone; never translate them literally or drop the attitude \
    they carry.
    - Code-switching. Indonesian speakers often mix in English words (meeting, deadline, \
    by the way, literally). Translate the meaning; when the target is Indonesian, keep English \
    loanwords only where Indonesians commonly use them in that context.
    - Pronouns. "Dia" and "-nya" have no gender: infer from context; if unclear, use "they" or \
    rephrase. Restore subjects that Indonesian drops when English needs them.
    - Idioms and culture-specific expressions (e.g. "masuk angin", "gak enakan", "insyaallah", \
    "jam karet"): use the closest natural equivalent; keep a term untranslated only if there is no \
    equivalent and it is widely understood.
    - ASR errors. If a segment contains an obvious mishearing, translate the most plausible \
    intended meaning instead of the garbled words.

    Rules:
    - Keep names, brands, numbers, units, and technical terms accurate. Follow the glossary if given.
    - Translate every segment separately and return it with the same id. Do not merge, split, \
    skip, or reorder segments. Use the context lines only to understand meaning; do not translate them.
    - If a segment is already in the target language, return it lightly cleaned up but unchanged in meaning.
    - Output only the translation text for each segment, with no notes or explanations.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "translations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "text": ["type": "string"],
                    ],
                    "required": ["id", "text"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["translations"],
        "additionalProperties": false,
    ]

    /// Menerjemahkan `texts[i]` untuk setiap `i` di `pending`. Seluruh `texts` dipakai sebagai
    /// konteks, sehingga segmen yang sudah diterjemahkan tidak perlu dikirim ulang.
    /// Hasil dilaporkan per kelompok lewat `onChunk`, jadi hasil yang sudah selesai tetap
    /// tersimpan walaupun kelompok lain gagal. Mengembalikan seluruh hasil saat semua selesai.
    func translate(
        _ texts: [String],
        pending: [Int],
        source: String?,
        target: String,
        glossary: String,
        onChunk: @escaping @Sendable ([Int: String]) -> Void
    ) async throws -> [Int: String] {
        guard !apiKey.isEmpty else { throw TranslatorError.missingAPIKey }

        let chunks = stride(from: 0, to: pending.count, by: chunkSize).map {
            Array(pending[$0..<min($0 + chunkSize, pending.count)])
        }
        var next = 0
        var all: [Int: String] = [:]

        try await withThrowingTaskGroup(of: [Int: String].self) { group in
            func enqueue() {
                guard next < chunks.count else { return }
                let ids = chunks[next]
                next += 1
                group.addTask {
                    try await translateChunk(ids, texts: texts, source: source,
                                             target: target, glossary: glossary)
                }
            }
            for _ in 0..<min(maxConcurrent, chunks.count) { enqueue() }

            while let result = try await group.next() {
                all.merge(result) { current, _ in current }
                onChunk(result)
                enqueue()
            }
        }
        return all
    }

    private func translateChunk(
        _ ids: [Int],
        texts: [String],
        source: String?,
        target: String,
        glossary: String,
        isRetry: Bool = false
    ) async throws -> [Int: String] {
        guard let first = ids.first else { return [:] }
        let contextRange = max(0, first - contextSize)..<first
        let sourceName = source.map(LanguageOption.englishName(for:)) ?? "auto-detect (usually Indonesian or English)"

        var prompt = "Source language: \(sourceName)\nTarget language: \(LanguageOption.englishName(for: target))\n"
        let trimmedGlossary = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGlossary.isEmpty {
            prompt += "\n<glossary>\n\(trimmedGlossary)\n</glossary>\n"
        }
        if !contextRange.isEmpty {
            prompt += "\n<context>\n"
            prompt += contextRange.map { texts[$0] }.joined(separator: "\n")
            prompt += "\n</context>\n"
        }
        prompt += "\n<segments>\n"
        prompt += ids.map { "[\($0)] \(texts[$0])" }.joined(separator: "\n")
        prompt += "\n</segments>"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            // Jika model menolak karena false positive, server otomatis mencoba model cadangan.
            "fallbacks": "default",
            "system": Self.systemPrompt,
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        let response = try JSONDecoder().decode(MessagesResponse.self, from: data)

        switch response.stop_reason {
        case "refusal": throw TranslatorError.refused
        case "max_tokens": throw TranslatorError.truncated
        default: break
        }

        // Respons bisa diawali blok "thinking"; JSON ada di blok "text".
        guard let json = response.content.first(where: { $0.type == "text" })?.text,
              let payload = try? JSONDecoder().decode(TranslationPayload.self, from: Data(json.utf8))
        else { throw TranslatorError.badResponse }

        let wanted = Set(ids)
        var result: [Int: String] = [:]
        for item in payload.translations where wanted.contains(item.id) {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result[item.id] = text }
        }

        // Segmen yang terlewat dikirim ulang sekali, bukan diisi teks asli diam-diam.
        let missing = ids.filter { result[$0] == nil }
        if !missing.isEmpty, !isRetry {
            let retried = try await translateChunk(missing, texts: texts, source: source,
                                                   target: target, glossary: glossary, isRetry: true)
            result.merge(retried) { current, _ in current }
        }
        return result
    }

    /// Mengirim request dengan retry untuk rate limit (429), overload (529), dan error server.
    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }

            let retryable = status == 429 || status >= 500
            if retryable, attempt < 4 {
                attempt += 1
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                let delay = retryAfter ?? pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? ""
            throw TranslatorError.api(status: status, message: message)
        }
    }
}

private struct MessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }
    let content: [Block]
    let stop_reason: String?
}

private struct TranslationPayload: Decodable {
    struct Item: Decodable {
        let id: Int
        let text: String
    }
    let translations: [Item]
}

private struct APIErrorResponse: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
