import AVFoundation
import Foundation

/// Waktu putar dipisah ke objek sendiri supaya hanya label waktu yang
/// di-render ulang setiap tick, bukan seluruh daftar transkrip.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
}

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Segmen yang sedang diputar. Hanya dipublikasikan saat berganti segmen.
    @Published private(set) var activeSegmentID: UUID?

    let clock = PlaybackClock()

    private var player: AVPlayer?
    private var url: URL?
    private var timeObserver: Any?
    private var cues: [(start: Double, end: Double, id: UUID)] = []

    func load(_ url: URL?) {
        guard url != self.url else { return }
        stop()
        self.url = url
        guard let url else { player = nil; return }

        let player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                self?.tick(time: time.seconds, playing: (player?.rate ?? 0) > 0)
            }
        }
        self.player = player
    }

    /// Daftar segmen (sudah urut berdasarkan waktu mulai) untuk sorotan segmen aktif.
    func setCues(_ segments: [Segment]) {
        cues = segments.map { ($0.start, $0.end, $0.id) }
        updateActiveSegment()
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        setPlaying(player.rate > 0)
    }

    func play(from seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        setPlaying(true)
    }

    func stop() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        setPlaying(false)
        if clock.time != 0 { clock.time = 0 }
    }

    // MARK: - Private

    private func tick(time: Double, playing: Bool) {
        guard time.isFinite else { return }
        clock.time = time
        setPlaying(playing)
        updateActiveSegment()
    }

    // @Published memicu render ulang walau nilainya sama, jadi selalu cek perubahan dulu.
    private func setPlaying(_ playing: Bool) {
        if isPlaying != playing { isPlaying = playing }
        if !playing { updateActiveSegment() }
    }

    /// Binary search O(log n) untuk segmen terakhir yang dimulai sebelum waktu sekarang.
    private func updateActiveSegment() {
        var id: UUID?
        if isPlaying, !cues.isEmpty {
            let t = clock.time
            var lo = 0, hi = cues.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, t < cues[lo - 1].end { id = cues[lo - 1].id }
        }
        if activeSegmentID != id { activeSegmentID = id }
    }
}
