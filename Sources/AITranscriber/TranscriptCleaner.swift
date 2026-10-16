import Foundation

/// Membersihkan "halusinasi" khas Whisper dari hasil transkripsi:
/// kata/frasa yang berulang-ulang, segmen kembar di batas potongan audio,
/// dan kalimat karangan pada bagian hening atau musik.
enum TranscriptCleaner {
    struct RawSegment {
        let start: Double
        let end: Double
        let text: String
        let avgLogprob: Float
        let noSpeechProb: Float
        let compressionRatio: Float
    }

    /// Kalimat yang sering "dikarang" Whisper saat audio hening/musik, karena banyak
    /// muncul di subtitle video yang dipakai untuk melatihnya.
    private static let hallucinationPhrases: [String] = [
        "terima kasih telah menonton", "terima kasih sudah menonton", "terima kasih",
        "sampai jumpa di video berikutnya", "sampai jumpa", "jangan lupa like dan subscribe",
        "jangan lupa subscribe", "silakan subscribe", "subtitle by", "subtitle oleh",
        "thanks for watching", "thank you for watching", "thank you",
        "please subscribe", "like and subscribe", "subtitles by the amara.org community",
        "terjemahan oleh", "diterjemahkan oleh",
    ]

    static func clean(_ raw: [RawSegment]) -> [Segment] {
        var result: [Segment] = []
        var previousKey = ""

        for seg in raw.sorted(by: { $0.start < $1.start }) {
            var text = stripSpecialTokens(seg.text)
            text = collapseRepeats(text)
            guard !text.isEmpty else { continue }

            let key = normalized(text)
            guard !key.isEmpty else { continue }

            // Bagian hening/musik dengan keyakinan rendah: hampir pasti karangan.
            if seg.noSpeechProb > 0.5 && seg.avgLogprob < -0.8 { continue }

            // Kalimat "penutup video" khas Whisper, hanya dibuang bila model tidak yakin.
            if hallucinationPhrases.contains(key), seg.avgLogprob < -0.4 || seg.noSpeechProb > 0.2 {
                continue
            }

            // Teks yang masih sangat berulang setelah dibersihkan, dengan keyakinan rendah.
            if seg.compressionRatio > 2.4 && seg.avgLogprob < -1.0 { continue }

            // Segmen kembar berurutan (sering muncul di batas potongan 30 detik).
            if key == previousKey { continue }

            previousKey = key
            result.append(Segment(start: seg.start, end: seg.end, text: text))
        }
        return result
    }

    static func stripSpecialTokens(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Memangkas frasa yang diulang 3 kali atau lebih berturut-turut menjadi satu.
    /// Pengulangan 2 kali dibiarkan karena wajar dalam percakapan ("iya iya", "oke oke").
    static func collapseRepeats(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3 else { return text }

        for n in stride(from: min(8, words.count / 3), through: 1, by: -1) {
            var i = 0
            while i + n * 3 <= words.count {
                let phrase = words[i..<i + n].map(normalized)
                var repeats = 1
                while i + n * (repeats + 1) <= words.count,
                      words[(i + n * repeats)..<(i + n * (repeats + 1))].map(normalized) == phrase {
                    repeats += 1
                }
                if repeats >= 3 {
                    words.removeSubrange((i + n)..<(i + n * repeats))
                }
                i += 1
            }
        }
        return words.joined(separator: " ")
    }

    /// Huruf kecil tanpa tanda baca, untuk membandingkan teks.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
