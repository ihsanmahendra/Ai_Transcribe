# AI Transcriber untuk macOS

Aplikasi Mac native (SwiftUI) untuk mentranskripsi audio/video memakai AI **Whisper**.
Pemrosesan berjalan **100% di perangkat** lewat [WhisperKit](https://github.com/argmaxinc/WhisperKit)
(CoreML + Apple Neural Engine). Transkripsi gratis, tanpa API key, dan audio tidak pernah dikirim ke internet.

## Fitur

- Tarik & lepas file (MP3, M4A, WAV, FLAC, AAC, MP4, MOV) atau buka lewat ⌘O
- Pilih model: Tiny, Base, Small, Large v3 Turbo (diunduh otomatis saat pertama dipakai). Setelah itu model dimuat langsung dari disk, jadi transkripsi tetap jalan tanpa internet
- File panjang (lebih dari 10 menit) dibaca bertahap supaya pemakaian memori tetap rendah
- **Mode "Indonesia + Inggris (campuran)"**: deteksi bahasa hanya memilih antara Indonesia dan Inggris, dan skor Melayu/Jawa/Sunda dihitung sebagai Indonesia (Whisper sering salah mengira bahasa Indonesia sebagai Melayu). Prompt gaya campuran membuat kata Inggris di tengah kalimat tetap ditulis apa adanya (*meeting*, *deadline*, *project-nya*)
- **Kosakata & istilah**: daftar nama, merek, dan singkatan agar ejaannya benar. Daftar yang sama juga dipakai sebagai glosarium terjemahan
- **Terjemahan Indonesia ⇄ Inggris**, ditampilkan di bawah teks asli:
  - **Claude AI** (disarankan): menerjemahkan per kelompok dengan konteks kalimat sebelumnya, peka terhadap formal/santai (saya/Anda vs gue/lo), partikel (*sih, dong, kok, deh, lho*), slang, idiom, kata ganti "dia" tanpa gender, campuran bahasa, dan salah dengar ASR. Butuh internet dan API key Anthropic
  - **Apple Translate**: gratis dan offline, menerjemahkan per kalimat
- Teks muncul langsung selama proses berjalan, dan proses bisa dibatalkan
- Transkrip bertimestamp. Klik timestamp untuk memutar audio dari titik itu, dan segmen yang sedang diputar disorot
- Cari kata di dalam transkrip
- Ekspor ke **TXT, SRT, VTT, Markdown** sebagai teks asli, terjemahan, atau **dwibahasa** (subtitle 2 baris), atau salin semua (⇧⌘C)

## Pengaturan terjemahan Claude

1. Buat API key di <https://console.anthropic.com/settings/keys>
2. Di sidebar → **Terjemahan** → pilih **Claude AI** → tempel API key → **Simpan** (disimpan di Keychain macOS)
3. Setelah transkripsi selesai, tekan **Terjemahkan** (⌘T). Target otomatis diatur ke kebalikan bahasa audio

Hanya teks transkrip yang dikirim ke Anthropic, bukan audionya. Model yang dipakai `claude-opus-5-5`.

## Kebutuhan

- macOS 15 (Sequoia) atau lebih baru (dibutuhkan untuk Apple Translate)
- Mac Apple Silicon (M1/M2/M3/M4) sangat disarankan
- Xcode 26 atau lebih baru (Xcode 16 tidak bisa: SwiftPM-nya menolak paket WhisperKit 1.x)

## Memasang sebagai aplikasi Mac

### Cara 1: Build di Mac sendiri (satu perintah)
Butuh Xcode 26+ dari App Store (buka sekali untuk menyetujui lisensi).

```bash
cd AITranscriber
make install        # atau: ./build-app.sh --install
```
Perintah ini meng-compile aplikasi, membuat **AI Transcriber.app** lengkap dengan ikon, memasangnya
ke folder **Applications**, lalu membukanya. Setelah itu aplikasi bisa dibuka dari Launchpad,
Spotlight, atau Dock seperti aplikasi biasa.

Perintah lain:

| Perintah | Hasil |
|---|---|
| `make app` | `build/AI Transcriber.app` saja |
| `make dmg` | `build/AI-Transcriber-<versi>.dmg` untuk dibagikan (Apple Silicon + Intel) |
| `make run` | Jalankan langsung tanpa bundle (development) |
| `make clean` | Hapus hasil build |

### Cara 2: Unduh DMG dari GitHub (tanpa Xcode)
Repo ini punya workflow GitHub Actions (`.github/workflows/build.yml`) yang mem-build aplikasi
di Mac milik GitHub setiap kali ada push ke `main`:

1. Push folder ini ke repositori GitHub
2. Buka tab **Actions** → run terbaru → unduh artifact **AI-Transcriber** (berisi `.dmg`)
3. Untuk rilis resmi: `git tag v1.0.0 && git push --tags`, maka DMG otomatis dilampirkan di halaman **Releases**

### Membuka pertama kali
Aplikasi ditandatangani *ad-hoc* (tanpa akun Apple Developer berbayar). Hasil build di Mac
sendiri langsung bisa dibuka. Untuk DMG yang **diunduh dari internet**, macOS akan memblokirnya
saat pertama kali dibuka:

- Buka **System Settings → Privacy & Security**, gulir ke bawah, lalu klik **Open Anyway**, atau
- Jalankan di Terminal: `xattr -dr com.apple.quarantine "/Applications/AI Transcriber.app"`

Agar tidak ada peringatan sama sekali, tanda tangani dengan sertifikat Developer ID dan notarisasi:
```bash
SIGN_IDENTITY="Developer ID Application: Nama Anda (TEAMID)" \
NOTARY_PROFILE="profil-notarytool" ./build-app.sh --universal --dmg
```

### Fitur integrasi macOS
- Klik kanan file audio/video di Finder → **Open With → AI Transcriber**
- Seret file ke ikon aplikasi di Dock
- Versi aplikasi diatur di file `VERSION`

### Development di Xcode
```bash
open Package.swift
```
Pilih skema **AITranscriber** → **My Mac**, lalu tekan ▶︎ (⌘R).

## Panduan memilih model

| Model | Ukuran | Kecepatan | Akurasi (B. Indonesia) |
|---|---|---|---|
| Tiny | ~75 MB | sangat cepat | rendah |
| Base | ~140 MB | cepat | cukup |
| Small | ~460 MB | sedang | baik |
| Large v3 Turbo | ~1.6 GB | lebih lambat | **terbaik** |

Pertama kali sebuah model dipakai, aplikasi mengunduhnya dari Hugging Face dan CoreML
mengompilasinya untuk chip Anda. Proses ini bisa makan beberapa menit. Setelah itu model
disimpan di cache (`~/Documents/huggingface/`), sehingga pemakaian berikutnya jauh lebih cepat.

## Struktur kode

```
Sources/AITranscriber/
├── AITranscriberApp.swift     # Entry point aplikasi + buka file dari Finder/Dock
├── ContentView.swift          # UI: sidebar, drop zone, transkrip, status bar
├── TranscriptionManager.swift # Unduh/muat model & transkripsi via WhisperKit
├── AudioPlayer.swift          # Pemutar audio + sinkronisasi timestamp
├── Translator.swift           # Penerjemah Claude (Messages API) + Keychain
├── Exporter.swift             # Ekspor TXT/SRT/VTT/MD (asli/terjemahan/dwibahasa)
└── Models.swift               # Tipe data, daftar model & bahasa
```
