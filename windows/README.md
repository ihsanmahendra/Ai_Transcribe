# AI Transcriber untuk Windows

Versi Windows (C# / WPF) dari AI Transcriber. Transkripsi berjalan 100% di PC lewat Whisper
([whisper.cpp](https://github.com/ggerganov/whisper.cpp) via Whisper.net, CPU). Audio tidak dikirim ke internet.

## Fitur
- Tarik & lepas atau buka file MP3, M4A, WAV, FLAC, AAC, MP4, MOV, MKV, OGG, WMA
- Model Tiny / Base / Small / Large v3 Turbo (diunduh sekali ke `%LOCALAPPDATA%\AITranscriber\models`)
- Mode "Indonesia + Inggris (campuran)" dengan voting bahasa dari beberapa potongan audio
- Pembersih halusinasi Whisper, kosakata/istilah khusus
- Terjemahan Indonesia ⇄ Inggris lewat Claude AI (API key disimpan terenkripsi DPAPI)
- Klik dua kali segmen untuk memutar audio dari titik itu, cari kata, ekspor TXT/SRT/VTT/MD (asli, terjemahan, dwibahasa)

Beda dari versi Mac: tidak ada Apple Translate, dan tidak ada akselerasi Neural Engine (CPU saja,
jadi pakai model Base/Small bila PC tidak kencang).

## Build
Butuh [.NET 8 SDK](https://dotnet.microsoft.com/download) di Windows:

```powershell
dotnet publish windows/AITranscriber.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o out
```

Atau ambil `AITranscriber.exe` dari artifact GitHub Actions (workflow *Build Windows app*).
