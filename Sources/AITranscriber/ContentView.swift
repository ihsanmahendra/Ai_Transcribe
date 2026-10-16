import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var manager: TranscriptionManager
    @EnvironmentObject private var player: AudioPlayer
    @State private var showImporter = false
    @State private var dropTargeted = false
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SettingsSidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if manager.fileURL == nil {
                    DropZone(isTargeted: dropTargeted) { showImporter = true }
                } else {
                    FileHeader()
                    Divider()
                    TranscriptView(search: search)
                }
                Divider()
                StatusBar()
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !manager.isBusy else { return false }
                manager.setFile(url)
                return true
            } isTargeted: { dropTargeted = $0 }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Cari di transkrip")
        .toolbar { toolbar }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .mpeg4Movie]) { result in
            if case .success(let url) = result { manager.setFile(url) }
        }
        .onChange(of: manager.fileURL) { _, url in player.load(url) }
        .onChange(of: manager.transcriptVersion) { player.setCues(manager.segments) }
        .translationTask(manager.appleTranslationConfig) { session in
            await manager.runAppleTranslation(session: session)
        }
    }

    private var copyContent: ExportContent {
        manager.showTranslation && manager.hasTranslation ? .bilingual : .original
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showImporter = true } label: {
                Label("Buka File", systemImage: "folder")
            }
            .keyboardShortcut("o")
            .disabled(manager.isBusy)

            if manager.isBusy {
                Button { manager.cancel() } label: {
                    Label("Batalkan", systemImage: "stop.fill")
                }
                .keyboardShortcut(".")
            } else {
                Button { manager.start() } label: {
                    Label("Transkrip", systemImage: "waveform.badge.mic")
                }
                .keyboardShortcut("r")
                .disabled(manager.fileURL == nil)

                Button { manager.translate() } label: {
                    Label("Terjemahkan ke \(manager.translationTarget.title)", systemImage: "globe")
                }
                .keyboardShortcut("t")
                .disabled(manager.segments.isEmpty)
                .help("Terjemahkan transkrip ke bahasa \(manager.translationTarget.title) (⌘T)")
            }

            Menu {
                ForEach(availableExportContents) { content in
                    Section(content.title) {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.title) {
                                Exporter.save(manager.segments, as: format, content: content,
                                              timestamps: manager.showTimestamps,
                                              sourceURL: manager.fileURL)
                            }
                        }
                    }
                }
            } label: {
                Label("Ekspor", systemImage: "square.and.arrow.up")
            }
            .disabled(manager.segments.isEmpty)

            Button {
                Exporter.copy(Exporter.render(manager.segments, as: .txt, content: copyContent,
                                              timestamps: manager.showTimestamps, title: ""))
            } label: {
                Label("Salin Semua", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(manager.segments.isEmpty)
        }
    }

    private var availableExportContents: [ExportContent] {
        manager.hasTranslation ? ExportContent.allCases : [.original]
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @EnvironmentObject private var manager: TranscriptionManager
    @State private var keyInput = ""

    var body: some View {
        Form {
            Section("Model AI (Whisper)") {
                Picker("Model", selection: $manager.selectedModel) {
                    ForEach(ModelOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Text(manager.selectedModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bahasa audio") {
                Picker("Bahasa", selection: $manager.language) {
                    ForEach(LanguageOption.all) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                if manager.language == LanguageOption.mixedCode {
                    Text("Paling cocok untuk obrolan Indonesia yang diselingi bahasa Inggris. Kata Inggris tetap ditulis apa adanya.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $manager.vocabulary)
                    .font(.callout)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Kosakata & istilah")
            } footer: {
                Text("Nama orang, merek, singkatan, istilah teknis. Pisahkan dengan koma. Dipakai untuk transkripsi dan sebagai glosarium terjemahan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terjemahan") {
                Picker("Terjemahkan ke", selection: $manager.translationTarget) {
                    ForEach(TranslationTarget.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Mesin", selection: $manager.translationEngine) {
                    ForEach(TranslationEngine.allCases) { Text($0.title).tag($0) }
                }
                Text(manager.translationEngine.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if manager.translationEngine == .claude {
                    apiKeyRow
                }
            }

            Section("Tampilan") {
                Toggle("Tampilkan timestamp", isOn: $manager.showTimestamps)
                Toggle("Tampilkan terjemahan", isOn: $manager.showTranslation)
                    .disabled(!manager.hasTranslation)
            }

            Section {
                Text("Transkripsi berjalan 100% di Mac Anda. Hanya terjemahan dengan Claude AI yang mengirim teks transkrip (bukan audio) ke Anthropic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(manager.isBusy)
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        if manager.hasClaudeKey {
            HStack {
                Label("API key tersimpan", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Hapus", role: .destructive) { manager.removeClaudeKey() }
                    .controlSize(.small)
            }
        } else {
            SecureField("API key Anthropic (sk-ant-…)", text: $keyInput)
            HStack {
                Link("Dapatkan API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
                Spacer()
                Button("Simpan") {
                    manager.saveClaudeKey(keyInput)
                    keyInput = ""
                }
                .controlSize(.small)
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Drop zone

private struct DropZone: View {
    let isTargeted: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Tarik & lepas file audio atau video di sini")
                .font(.title3.weight(.medium))
            Text("MP3, M4A, WAV, FLAC, AAC, MP4, MOV")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Pilih File…", action: onOpen)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(24)
        )
    }
}

// MARK: - File header

private struct FileHeader: View {
    @EnvironmentObject private var manager: TranscriptionManager
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .help("Putar / jeda")

            VStack(alignment: .leading, spacing: 2) {
                Text(manager.fileURL?.lastPathComponent ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    PlaybackTimeLabel(clock: player.clock)
                    if let duration = manager.fileDuration {
                        Text("/ \(formatClock(duration))")
                    }
                    if let lang = manager.detectedLanguage {
                        Text("· \(LanguageOption.name(for: lang))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { player.stop(); manager.clearFile() } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(manager.isBusy)
            .help("Tutup file")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Satu-satunya view yang mengamati waktu putar (update 4x per detik).
private struct PlaybackTimeLabel: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text(formatClock(clock.time))
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    @EnvironmentObject private var manager: TranscriptionManager
    @EnvironmentObject private var player: AudioPlayer
    let search: String

    private var visibleSegments: [Segment] {
        guard !search.isEmpty else { return manager.segments }
        return manager.segments.filter {
            $0.text.localizedCaseInsensitiveContains(search)
                || ($0.translation?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        if manager.segments.isEmpty {
            placeholder
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleSegments) { seg in
                            SegmentRow(segment: seg,
                                       showTimestamp: manager.showTimestamps,
                                       showTranslation: manager.showTranslation,
                                       isActive: seg.id == player.activeSegmentID) {
                                player.play(from: seg.start)
                            }
                            .id(seg.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: player.activeSegmentID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if manager.status == .transcribing, !manager.liveText.isEmpty {
            ScrollView {
                Text(manager.liveText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(manager.isBusy ? "Sedang memproses…" : "Tekan \"Transkrip\" (⌘R) untuk mulai")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SegmentRow: View {
    let segment: Segment
    let showTimestamp: Bool
    let showTranslation: Bool
    let isActive: Bool
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showTimestamp {
                Button(action: onSeek) {
                    Text(formatClock(segment.start))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Putar dari sini")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(segment.text)
                    .font(.body)
                if showTranslation, let translation = segment.translation {
                    Text(translation)
                        .font(.body)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
        )
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @EnvironmentObject private var manager: TranscriptionManager

    var body: some View {
        HStack(spacing: 10) {
            if manager.translationStatus == .idle {
                transcriptionStatus
            } else {
                translationStatus
            }
            Spacer()
            if !manager.segments.isEmpty {
                Text("\(manager.segments.count) segmen · \(manager.wordCount) kata")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(.bar)
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch manager.status {
        case .idle:
            Text(manager.fileURL == nil ? "Siap" : "File dimuat")
                .foregroundStyle(.secondary)
        case .downloading(let model, let fraction):
            ProgressView(value: fraction).frame(width: 120)
            Text("Mengunduh model \(model)… \(Int(fraction * 100))%")
        case .loadingModel(let model):
            ProgressView().controlSize(.small)
            Text("Memuat model \(model) (pertama kali bisa agak lama)…")
        case .detectingLanguage:
            ProgressView().controlSize(.small)
            Text("Mendeteksi bahasa (Indonesia/Inggris)…")
        case .transcribing:
            ProgressView().controlSize(.small)
            Text("Mentranskripsi…")
        case .done(let seconds, let language):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Selesai dalam \(String(format: "%.1f", seconds)) detik"
                 + (language.map { " · bahasa: \(LanguageOption.name(for: $0))" } ?? ""))
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.orange)
            Text("Dibatalkan")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("Gagal: \(message)").lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var translationStatus: some View {
        switch manager.translationStatus {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 120)
            Text("Menerjemahkan dengan \(manager.translationEngine.title)… \(done)/\(total)")
        case .done:
            Image(systemName: "globe").foregroundStyle(.green)
            Text("Terjemahan ke bahasa \(manager.translationTarget.title) selesai")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text("Terjemahan gagal: \(message)").lineLimit(1).truncationMode(.tail)
        }
    }
}
