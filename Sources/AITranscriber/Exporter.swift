import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, vtt, md

    var id: String { rawValue }

    var title: String {
        switch self {
        case .txt: return "Teks biasa (.txt)"
        case .srt: return "Subtitle SubRip (.srt)"
        case .vtt: return "Subtitle WebVTT (.vtt)"
        case .md: return "Markdown (.md)"
        }
    }
}

enum Exporter {
    static func render(
        _ segments: [Segment],
        as format: ExportFormat,
        content: ExportContent,
        timestamps: Bool,
        title: String
    ) -> String {
        switch format {
        case .txt:
            return segments.map { seg in
                let body = lines(seg, content).joined(separator: "\n    ")
                return timestamps ? "[\(formatClock(seg.start))] \(body)" : body
            }.joined(separator: content == .bilingual ? "\n\n" : "\n") + "\n"

        case .md:
            let body = segments.map { seg in
                let parts = lines(seg, content)
                var text = timestamps ? "**[\(formatClock(seg.start))]** \(parts[0])" : parts[0]
                if parts.count > 1 { text += "  \n*\(parts[1])*" }
                return text
            }.joined(separator: "\n\n")
            return "# \(title)\n\n\(body)\n"

        case .srt:
            return segments.enumerated().map { index, seg in
                "\(index + 1)\n\(stamp(seg.start, ",")) --> \(stamp(seg.end, ","))\n"
                    + lines(seg, content).joined(separator: "\n") + "\n"
            }.joined(separator: "\n")

        case .vtt:
            let cues = segments.map { seg in
                "\(stamp(seg.start, ".")) --> \(stamp(seg.end, "."))\n"
                    + lines(seg, content).joined(separator: "\n") + "\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + cues
        }
    }

    private static func lines(_ seg: Segment, _ content: ExportContent) -> [String] {
        switch content {
        case .original:
            return [seg.text]
        case .translation:
            return [seg.translation ?? seg.text]
        case .bilingual:
            return seg.translation.map { [seg.text, $0] } ?? [seg.text]
        }
    }

    static func stamp(_ seconds: Double, _ separator: String) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, r = ms % 1000
        return String(format: "%02d:%02d:%02d", h, m, s) + separator + String(format: "%03d", r)
    }

    @MainActor
    static func save(
        _ segments: [Segment],
        as format: ExportFormat,
        content: ExportContent,
        timestamps: Bool,
        sourceURL: URL?
    ) {
        var baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "transkrip"
        if content == .translation { baseName += "-terjemahan" }
        if content == .bilingual { baseName += "-dwibahasa" }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).\(format.rawValue)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = render(segments, as: format, content: content, timestamps: timestamps, title: baseName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
