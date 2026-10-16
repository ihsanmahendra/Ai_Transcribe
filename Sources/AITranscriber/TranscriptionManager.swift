import AVFoundation
import Foundation
import Translation
import WhisperKit

@MainActor
final class TranscriptionManager: ObservableObject {
    @Published var fileURL: URL?
    @Published var fileDuration: Double?
    @Published private(set) var segments: [Segment] = [] {
        didSet {
            wordCount = segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            hasTranslation = segments.contains { $0.translation != nil }
        }
    }
    /// Naik setiap kali hasil transkripsi baru masuk (bukan saat terjemahan berubah).
    @Published private(set) var transcriptVersion = 0
    @Published private(set) var wordCount = 0
    @Published private(set) var hasTranslation = false
    @Published var liveText = ""
    @Published var status: TranscriptionStatus = .idle
    /// Progres transkripsi 0...1 dan perkiraan sisa waktu (detik), diperbarui 2x per detik.
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var remainingSeconds: Double?
    @Published var detectedLanguage: String?

    // Pengaturan transkripsi
    @Published var selectedModel: ModelOption {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "model") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var vocabulary: String {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    @Published var showTimestamps: Bool {
        didSet { UserDefaults.standard.set(showTimestamps, forKey: "showTimestamps") }
    }

    // Pengaturan terjemahan
    @Published var translationEngine: TranslationEngine {
        didSet { UserDefaults.standard.set(translationEngine.rawValue, forKey: "translationEngine") }
    }
    @Published var translationTarget: TranslationTarget = .english
    @Published var showTranslation = true
    @Published var translationStatus: TranslationStatus = .idle
    @Published var appleTranslationConfig: TranslationSession.Configuration?
    @Published private(set) var hasClaudeKey: Bool

    /// Bahasa tujuan dari terjemahan yang sudah ada di `segments`.
    private var translatedTarget: TranslationTarget?
    private var whisperKit: WhisperKit?
    private var loadedModel: ModelOption?
    private var job: Task<Void, Never>?
    private var durationJob: Task<Void, Never>?
    private var translationJob: Task<Void, Never>?
    private var cancelFlag = CancelFlag()

    /// Batas panjang prompt (token). Setiap token prompt diproses decoder satu per satu di
    /// SETIAP jendela audio 30 detik, jadi prompt panjang membuat transkripsi jauh lebih lambat.
    private static let maxPromptTokens = 48

    init() {
        let defaults = UserDefaults.standard
        selectedModel = ModelOption(rawValue: defaults.string(forKey: "model") ?? "") ?? .largeTurbo
        language = defaults.string(forKey: "language") ?? LanguageOption.mixedCode
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        showTimestamps = defaults.object(forKey: "showTimestamps") as? Bool ?? true
        translationEngine = TranslationEngine(rawValue: defaults.string(forKey: "translationEngine") ?? "") ?? .claude
        hasClaudeKey = Self.claudeKey != nil
    }

    var isBusy: Bool { status.isBusy || translationStatus.isRunning }

    // MARK: - File

    func setFile(_ url: URL) {
        guard !isBusy else { return }
        fileURL = url
        resetResults()
        fileDuration = nil
        durationJob?.cancel()
        durationJob = Task {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), !Task.isCancelled else { return }
            fileDuration = duration.seconds.isFinite ? duration.seconds : nil
        }
    }

    func clearFile() {
        guard !isBusy else { return }
        durationJob?.cancel()
        fileURL = nil
        fileDuration = nil
        resetResults()
    }

    private func resetResults() {
        segments = []
        transcriptVersion += 1
        translatedTarget = nil
        liveText = ""
        detectedLanguage = nil
        status = .idle
        translationStatus = .idle
    }

    // MARK: - Transcription

    func start() {
        guard let url = fileURL, !isBusy else { return }
        cancelFlag = CancelFlag()
        let flag = cancelFlag
        resetResults()

        job = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let pipe = try await prepareModel(flag: flag)
                guard !flag.isCancelled else { status = .cancelled; return }

                // 1. Tentukan bahasa yang dipakai untuk decoding.
                var decodeLanguage: String? = language == "auto" ? nil : language
                if language == LanguageOption.mixedCode {
                    status = .detectingLanguage
                    decodeLanguage = try await detectIndonesianOrEnglish(pipe: pipe, path: url.path)
                }

                status = .transcribing
                let began = Date()

                // 2. Opsi decoding yang disetel untuk bahasa Indonesia & Inggris.
                var options = DecodingOptions()
                options.task = .transcribe
                options.skipSpecialTokens = true
                options.withoutTimestamps = false
                options.chunkingStrategy = .vad
                // Jendela yang hasilnya berulang-ulang (compression ratio tinggi) atau tidak yakin
                // diulang dengan temperature lebih tinggi (default WhisperKit: hingga 5x).
                // Ini pengaman utama terhadap pengulangan kata, jadi tidak dikurangi.
                options.suppressBlank = true
                if let decodeLanguage {
                    options.language = decodeLanguage
                    options.usePrefillPrompt = true
                    options.detectLanguage = false
                } else {
                    options.language = nil
                    options.usePrefillPrompt = false
                    options.detectLanguage = true
                }

                // 3. Prompt hanya berisi kosakata dari pengguna (jika ada). Whisper cenderung
                //    menyalin isi prompt ke bagian yang hening, jadi tidak ada kalimat contoh.
                let promptText = Self.buildPrompt(vocabulary: vocabulary)
                if !promptText.isEmpty, let tokenizer = pipe.tokenizer {
                    let tokens = tokenizer.encode(text: " " + promptText)
                        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    // Bagian akhir (kosakata pengguna) yang dipertahankan bila terlalu panjang.
                    options.promptTokens = Array(tokens.suffix(Self.maxPromptTokens))
                }

                // File dimuat utuh: WhisperKit lalu memproses hingga 16 jendela audio secara paralel.
                // (Mode .incremental memproses jendela satu per satu, jauh lebih lambat.)
                let progressTask = trackProgress(of: pipe, startedAt: began)
                defer { progressTask.cancel() }

                let callback = Self.makeProgressCallback(flag: flag) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.status == .transcribing else { return }
                        self.liveText = text
                    }
                }

                let results = try await pipe.transcribe(
                    audioPath: url.path,
                    decodeOptions: options,
                    callback: callback
                )

                if flag.isCancelled {
                    status = .cancelled
                    return
                }

                let detected = decodeLanguage ?? results.first?.language
                segments = TranscriptCleaner.clean(results.flatMap(\.segments).map {
                    TranscriptCleaner.RawSegment(
                        start: Double($0.start), end: Double($0.end), text: $0.text,
                        avgLogprob: $0.avgLogprob, noSpeechProb: $0.noSpeechProb,
                        compressionRatio: $0.compressionRatio
                    )
                })
                transcriptVersion += 1
                liveText = ""
                detectedLanguage = detected
                translationTarget = .opposite(of: detected)
                status = .done(seconds: Date().timeIntervalSince(began), language: detected)
            } catch {
                status = flag.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    /// Membaca `WhisperKit.progress` (jumlah jendela audio yang selesai) secara berkala,
    /// lalu menghitung persentase dan perkiraan sisa waktu.
    private func trackProgress(of pipe: WhisperKit, startedAt began: Date) -> Task<Void, Never> {
        progressFraction = 0
        remainingSeconds = nil
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.status == .transcribing else { return }
                let fraction = min(max(pipe.progress.fractionCompleted, 0), 1)
                let elapsed = Date().timeIntervalSince(began)
                if fraction > self.progressFraction { self.progressFraction = fraction }
                // Perkiraan baru masuk akal setelah ada progres dan beberapa detik berjalan.
                if self.progressFraction > 0.03, elapsed > 3 {
                    let estimate = elapsed / self.progressFraction * (1 - self.progressFraction)
                    self.remainingSeconds = estimate
                }
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
        job?.cancel()
        translationJob?.cancel()
        if translationStatus.isRunning { translationStatus = .idle }
    }

    /// Memilih bahasa Indonesia atau Inggris dengan "voting" dari beberapa potongan 30 detik
    /// yang tersebar di sepanjang file. Mengandalkan 30 detik pertama saja rawan salah
    /// (intro musik, salam pembuka bahasa Inggris, dll.).
    /// Whisper sering mengira bahasa Indonesia sebagai Melayu/Jawa/Sunda, jadi semuanya dihitung
    /// sebagai Indonesia. Bila seri atau ragu, dipilih Indonesia: memaksa bahasa Inggris pada
    /// audio Indonesia menghasilkan teks kacau, sedangkan sebaliknya relatif aman.
    private func detectIndonesianOrEnglish(pipe: WhisperKit, path: String) async throws -> String {
        let duration = fileDuration ?? 0
        let positions: [Double] = duration > 120 ? [0.08, 0.3, 0.52, 0.74, 0.92] : [0]
        var indonesianVotes = 0
        var englishVotes = 0

        for position in positions {
            let start = max(0, duration * position - 15)
            let samples = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: path, startTime: start, endTime: start + 30
            )
            guard samples.count > WhisperKit.sampleRate * 2 else { continue }
            let detected = try await pipe.detectLangauge(audioArray: samples).language
            if LanguageOption.indonesianFamily.contains(detected) {
                indonesianVotes += 1
            } else if detected == "en" {
                englishVotes += 1
            }
        }
        return englishVotes > indonesianVotes ? "en" : "id"
    }

    /// Prompt berisi daftar istilah dari pengguna agar ejaan nama & istilah benar.
    nonisolated private static func buildPrompt(vocabulary: String) -> String {
        let terms = vocabulary
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return terms.isEmpty ? "" : terms.joined(separator: ", ") + "."
    }

    // MARK: - Model

    private func prepareModel(flag: CancelFlag) async throws -> WhisperKit {
        if let whisperKit, loadedModel == selectedModel {
            return whisperKit
        }
        whisperKit = nil
        loadedModel = nil
        let model = selectedModel

        // Model yang sudah pernah diunduh dipakai langsung dari disk: tanpa request ke
        // Hugging Face, sehingga lebih cepat dan tetap jalan saat offline.
        if let cached = Self.cachedModelFolder(model) {
            do {
                return try await loadModel(model, from: cached, prewarm: false)
            } catch {
                // Folder rusak/tidak lengkap: hapus catatan lalu unduh ulang.
                UserDefaults.standard.removeObject(forKey: Self.modelFolderKey(model))
            }
        }

        status = .downloading(model: model.title, fraction: 0)
        let throttle = Throttle(interval: 0.2)
        let folder = try await WhisperKit.download(
            variant: model.rawValue,
            progressCallback: Self.makeDownloadCallback(throttle: throttle) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.status {
                        self?.status = .downloading(model: model.title, fraction: fraction)
                    }
                }
            }
        )
        guard !flag.isCancelled else { throw CancellationError() }
        UserDefaults.standard.set(folder.path, forKey: Self.modelFolderKey(model))

        // Prewarm hanya perlu setelah unduhan baru: CoreML mengoptimasi model untuk chip ini
        // dengan memori puncak lebih rendah. Pada pemuatan berikutnya prewarm cuma
        // menggandakan waktu muat.
        return try await loadModel(model, from: folder, prewarm: true)
    }

    private func loadModel(_ model: ModelOption, from folder: URL, prewarm: Bool) async throws -> WhisperKit {
        status = .loadingModel(model: model.title)
        let config = WhisperKitConfig(modelFolder: folder.path)
        config.verbose = false
        config.prewarm = prewarm
        config.load = true
        config.download = false

        let pipe = try await WhisperKit(config)
        whisperKit = pipe
        loadedModel = model
        return pipe
    }

    private static func modelFolderKey(_ model: ModelOption) -> String {
        "modelFolder.\(model.rawValue)"
    }

    private static func cachedModelFolder(_ model: ModelOption) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: modelFolderKey(model)) else { return nil }
        let folder = URL(fileURLWithPath: path)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let complete = required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return complete ? folder : nil
    }

    // MARK: - Translation

    private var translationSource: String? {
        guard let detectedLanguage else { return nil }
        return LanguageOption.indonesianFamily.contains(detectedLanguage) ? "id" : detectedLanguage
    }

    func translate() {
        guard !segments.isEmpty, !isBusy else { return }
        showTranslation = true

        // Target berubah: terjemahan lama tidak berlaku lagi.
        if translatedTarget != translationTarget {
            if hasTranslation {
                segments = segments.map { var seg = $0; seg.translation = nil; return seg }
            }
            translatedTarget = translationTarget
        }

        // Hanya segmen yang belum diterjemahkan, jadi mengulang setelah gagal tidak
        // mengirim (dan membayar) ulang bagian yang sudah selesai.
        let pending = segments.indices.filter { segments[$0].translation == nil }
        guard !pending.isEmpty else {
            translationStatus = .done
            return
        }
        translationStatus = .running(done: segments.count - pending.count, total: segments.count)

        switch translationEngine {
        case .claude:
            translateWithClaude(pending: pending)
        case .apple:
            // Mengubah konfigurasi memicu .translationTask di ContentView.
            let config = TranslationSession.Configuration(
                source: translationSource.map { Locale.Language(identifier: $0) },
                target: Locale.Language(identifier: translationTarget.rawValue)
            )
            if appleTranslationConfig?.source == config.source,
               appleTranslationConfig?.target == config.target {
                appleTranslationConfig?.invalidate()
            } else {
                appleTranslationConfig = config
            }
        }
    }

    private func translateWithClaude(pending: [Int]) {
        guard let key = Self.claudeKey else {
            translationStatus = .failed(TranslatorError.missingAPIKey.localizedDescription)
            return
        }
        let ids = segments.map(\.id)
        let texts = segments.map(\.text)
        let source = translationSource
        let targetOption = translationTarget
        let target = targetOption.rawValue
        let glossary = vocabulary

        translationJob = Task {
            do {
                let all = try await ClaudeTranslator(apiKey: key).translate(
                    texts, pending: pending, source: source, target: target, glossary: glossary
                ) { [weak self] chunk in
                    let map = Dictionary(uniqueKeysWithValues: chunk.map { (ids[$0.key], $0.value) })
                    Task { @MainActor in self?.applyTranslations(map, target: targetOption) }
                }
                // Terapkan ulang hasil akhir (idempoten) agar status selesai tidak
                // mendahului update per kelompok yang masih antre.
                applyTranslations(Dictionary(uniqueKeysWithValues: all.map { (ids[$0.key], $0.value) }),
                                  target: targetOption)
                finishTranslation()
            } catch is CancellationError {
                translationStatus = .idle
            } catch {
                translationStatus = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    /// Dipanggil dari .translationTask ketika memakai Apple Translate.
    func runAppleTranslation(session: TranslationSession) async {
        let requests = segments
            .filter { $0.translation == nil }
            .map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString) }
        guard !requests.isEmpty, let target = translatedTarget else { finishTranslation(); return }

        do {
            try await session.prepareTranslation()
            // Hasil diterapkan bertahap per 20 segmen agar progres terlihat tanpa
            // memicu render ulang untuk setiap kalimat.
            var buffer: [UUID: String] = [:]
            for try await response in session.translate(batch: requests) {
                if let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)) {
                    buffer[id] = response.targetText
                }
                if buffer.count >= 20 {
                    applyTranslations(buffer, target: target)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            applyTranslations(buffer, target: target)
            finishTranslation()
        } catch {
            translationStatus = .failed(error.localizedDescription)
        }
    }

    /// Menerapkan terjemahan dengan satu kali penugasan array (satu render ulang),
    /// bukan memodifikasi elemen satu per satu.
    private func applyTranslations(_ map: [UUID: String], target: TranslationTarget) {
        // Abaikan hasil terlambat dari terjemahan lama yang targetnya sudah diganti.
        guard !map.isEmpty, target == translatedTarget else { return }
        var updated = segments
        for index in updated.indices {
            if let text = map[updated[index].id] { updated[index].translation = text }
        }
        segments = updated
        if case .running(_, let total) = translationStatus {
            translationStatus = .running(done: segments.count(where: { $0.translation != nil }), total: total)
        }
    }

    private func finishTranslation() {
        let missing = segments.count(where: { $0.translation == nil })
        translationStatus = missing == 0
            ? .done
            : .failed("\(missing) segmen belum diterjemahkan. Tekan Terjemahkan lagi untuk melanjutkan.")
    }

    // MARK: - API key

    private static let keyAccount = "anthropic-api-key"

    private static var claudeKey: String? {
        if let stored = Keychain.get(keyAccount), !stored.isEmpty { return stored }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    func saveClaudeKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyAccount)
        hasClaudeKey = Self.claudeKey != nil
    }

    func removeClaudeKey() {
        Keychain.set(nil, for: Self.keyAccount)
        hasClaudeKey = Self.claudeKey != nil
    }

    // MARK: - Callbacks

    // Callback dibuat di luar MainActor karena WhisperKit memanggilnya dari thread latar belakang.
    // WhisperKit memanggilnya untuk setiap token, jadi update UI dibatasi ~8x per detik.
    nonisolated private static func makeProgressCallback(
        flag: CancelFlag,
        onText: @escaping @Sendable (String) -> Void
    ) -> TranscriptionCallback {
        let throttle = Throttle(interval: 0.12)
        return { progress in
            if throttle.shouldFire() { onText(progress.text) }
            return flag.isCancelled ? false : nil
        }
    }

    nonisolated private static func makeDownloadCallback(
        throttle: Throttle,
        onFraction: @escaping @Sendable (Double) -> Void
    ) -> @Sendable (Progress) -> Void {
        return { progress in
            if throttle.shouldFire() || progress.fractionCompleted >= 1 {
                onFraction(progress.fractionCompleted)
            }
        }
    }
}
