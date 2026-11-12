using System.Net.Http;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Whisper.net;

namespace AITranscriber;

public record TranscribeOptions(string ModelId, string Language, string Vocabulary);

/// Transkripsi lokal dengan Whisper (whisper.cpp lewat Whisper.net). Audio tidak dikirim ke internet.
public class Transcriber
{
    static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public static string ModelDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AITranscriber", "models");

    public static string ModelPath(string id) => Path.Combine(ModelDir, $"ggml-{id}.bin");

    /// Mengunduh model GGML dari Hugging Face bila belum ada.
    public static async Task EnsureModelAsync(string id, IProgress<double> progress, CancellationToken ct)
    {
        var path = ModelPath(id);
        if (File.Exists(path)) return;
        Directory.CreateDirectory(ModelDir);
        var tmp = path + ".part";
        var url = $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{id}.bin";
        using var resp = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        long total = resp.Content.Headers.ContentLength ?? 0;
        await using (var src = await resp.Content.ReadAsStreamAsync(ct))
        await using (var dst = File.Create(tmp))
        {
            var buf = new byte[1 << 16];
            long read = 0; int n;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                read += n;
                if (total > 0) progress.Report((double)read / total);
            }
        }
        File.Move(tmp, path, true);
    }

    /// Mengubah audio/video apa pun menjadi WAV 16 kHz mono (format yang dibutuhkan Whisper).
    public static string ToWav16k(string input, double startSec = 0, double? lengthSec = null)
    {
        var output = Path.Combine(Path.GetTempPath(), $"aitr-{Guid.NewGuid():N}.wav");
        using var reader = new MediaFoundationReader(input);
        if (startSec > 0) reader.CurrentTime = TimeSpan.FromSeconds(startSec);
        ISampleProvider sp = reader.ToSampleProvider();
        if (sp.WaveFormat.Channels > 1) sp = new StereoToMonoSampleProvider(sp) { LeftVolume = 0.5f, RightVolume = 0.5f };
        if (sp.WaveFormat.SampleRate != 16000) sp = new WdlResamplingSampleProvider(sp, 16000);
        if (lengthSec is double len) sp = new OffsetSampleProvider(sp) { Take = TimeSpan.FromSeconds(len) };
        WaveFileWriter.CreateWaveFile16(output, sp);
        return output;
    }

    public static double Duration(string input)
    {
        using var r = new MediaFoundationReader(input);
        return r.TotalTime.TotalSeconds;
    }

    static string? BuildPrompt(string vocabulary)
    {
        var terms = vocabulary.Split(new[] { ',', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(t => t.Trim()).Where(t => t.Length > 0).ToList();
        return terms.Count == 0 ? null : string.Join(", ", terms) + ".";
    }

    /// Voting bahasa dari beberapa potongan 30 detik; keluarga Melayu/Jawa/Sunda dihitung sebagai Indonesia.
    static async Task<string> DetectIdOrEnAsync(WhisperFactory factory, string input, double duration, CancellationToken ct)
    {
        double[] positions = duration > 120 ? new[] { 0.08, 0.3, 0.52, 0.74, 0.92 } : new[] { 0.0 };
        int id = 0, en = 0;
        await using var detector = factory.CreateBuilder().WithLanguage("auto").Build();
        foreach (var p in positions)
        {
            ct.ThrowIfCancellationRequested();
            var clip = ToWav16k(input, Math.Max(0, duration * p - 15), 30);
            try
            {
                await using var fs = File.OpenRead(clip);
                await foreach (var seg in detector.ProcessAsync(fs, ct))
                {
                    var lang = seg.Language;
                    if (LanguageOption.IndonesianFamily.Contains(lang)) id++;
                    else if (lang == "en") en++;
                    break;
                }
            }
            finally { File.Delete(clip); }
        }
        return en > id ? "en" : "id";
    }

    public static async Task<(List<Segment> Segments, string? Language)> RunAsync(
        string input, TranscribeOptions opt, double duration,
        Action<string> onStatus, Action<double, string> onLive, CancellationToken ct)
    {
        using var factory = WhisperFactory.FromPath(ModelPath(opt.ModelId));

        string? lang = opt.Language == "auto" ? null : opt.Language;
        if (opt.Language == LanguageOption.Mixed)
        {
            onStatus("Mendeteksi bahasa…");
            lang = await DetectIdOrEnAsync(factory, input, duration, ct);
        }

        onStatus("Menyiapkan audio…");
        var wav = ToWav16k(input);
        try
        {
            onStatus("Mentranskripsi…");
            var builder = factory.CreateBuilder().WithLanguage(lang ?? "auto")
                .WithThreads(Math.Max(2, Environment.ProcessorCount - 1));
            if (BuildPrompt(opt.Vocabulary) is string prompt) builder = builder.WithPrompt(prompt);
            await using var processor = builder.Build();

            var raw = new List<TranscriptCleaner.RawSegment>();
            string? detected = lang;
            await using var fs = File.OpenRead(wav);
            await foreach (var s in processor.ProcessAsync(fs, ct))
            {
                detected ??= s.Language;
                raw.Add(new(s.Start.TotalSeconds, s.End.TotalSeconds, s.Text,
                    (float)Math.Log(Math.Max(1e-6, s.Probability)), s.NoSpeechProbability, 0));
                onLive(duration > 0 ? Math.Min(1, s.End.TotalSeconds / duration) : 0, s.Text.Trim());
            }
            return (TranscriptCleaner.Clean(raw), detected);
        }
        finally { File.Delete(wav); }
    }
}
