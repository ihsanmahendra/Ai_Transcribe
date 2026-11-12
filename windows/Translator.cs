using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AITranscriber;

/// Penyimpanan API key terenkripsi DPAPI (hanya bisa dibuka oleh akun Windows ini).
public static class SecretStore
{
    static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AITranscriber", "claude.key");

    public static string? Get()
    {
        try
        {
            if (!File.Exists(FilePath)) return null;
            var raw = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(raw);
        }
        catch { return null; }
    }

    public static void Set(string? key)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        if (string.IsNullOrWhiteSpace(key)) { if (File.Exists(FilePath)) File.Delete(FilePath); return; }
        File.WriteAllBytes(FilePath, ProtectedData.Protect(Encoding.UTF8.GetBytes(key.Trim()), null, DataProtectionScope.CurrentUser));
    }
}

/// Menerjemahkan segmen Indonesia ⇄ Inggris lewat Claude Messages API, per kelompok dengan konteks sebelumnya.
public class ClaudeTranslator
{
    public string ApiKey { get; init; } = "";
    public string Model { get; init; } = "claude-opus-5-5";
    const int ChunkSize = 40, ContextSize = 8, MaxConcurrent = 4;
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(300) };

    const string SystemPrompt = """
    You are an expert Indonesian–English subtitle translator who is a native speaker of both languages. You translate speech transcripts produced by automatic speech recognition (ASR).

    Translate each numbered segment into the target language so it reads like natural speech a native speaker would actually say, not a word-for-word translation.

    Be sensitive to:
    - Register and tone. Indonesian distinguishes formal speech (saya, Anda, Bapak/Ibu) from casual speech (aku/kamu, gue/lo, slang such as "anjir", "gokil", "mager", "baper", "wkwk"). Mirror the speaker's level of formality in the target language. When translating into Indonesian, pick the register that matches the English speaker's tone (casual English → casual Indonesian, professional English → baku but natural Indonesian).
    - Discourse particles (sih, dong, kok, deh, lho, kan, ya, nih, tuh, mah, kayak). Convey their nuance through English phrasing or tone; never translate them literally or drop the attitude they carry.
    - Code-switching. Indonesian speakers often mix in English words (meeting, deadline, by the way, literally). Translate the meaning; when the target is Indonesian, keep English loanwords only where Indonesians commonly use them in that context.
    - Pronouns. "Dia" and "-nya" have no gender: infer from context; if unclear, use "they" or rephrase. Restore subjects that Indonesian drops when English needs them.
    - Idioms and culture-specific expressions (e.g. "masuk angin", "gak enakan", "insyaallah", "jam karet"): use the closest natural equivalent; keep a term untranslated only if there is no equivalent and it is widely understood.
    - ASR errors. If a segment contains an obvious mishearing, translate the most plausible intended meaning instead of the garbled words.

    Rules:
    - Keep names, brands, numbers, units, and technical terms accurate. Follow the glossary if given.
    - Translate every segment separately and return it with the same id. Do not merge, split, skip, or reorder segments. Use the context lines only to understand meaning; do not translate them.
    - If a segment is already in the target language, return it lightly cleaned up but unchanged in meaning.
    - Output only the translation text for each segment, with no notes or explanations.
    """;

    static JsonNode Schema() => JsonNode.Parse("""
    {"type":"object","properties":{"translations":{"type":"array","items":{"type":"object",
    "properties":{"id":{"type":"integer"},"text":{"type":"string"}},
    "required":["id","text"],"additionalProperties":false}}},
    "required":["translations"],"additionalProperties":false}
    """)!;

    public async Task<Dictionary<int, string>> TranslateAsync(
        IReadOnlyList<string> texts, IReadOnlyList<int> pending, string? source, string target,
        string glossary, Action<Dictionary<int, string>> onChunk, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(ApiKey)) throw new InvalidOperationException("API key Claude belum diisi.");
        var chunks = pending.Chunk(ChunkSize).ToList();
        var all = new Dictionary<int, string>();
        using var gate = new SemaphoreSlim(MaxConcurrent);

        var tasks = chunks.Select(async ids =>
        {
            await gate.WaitAsync(ct);
            try
            {
                var r = await ChunkAsync(ids, texts, source, target, glossary, false, ct);
                lock (all) foreach (var kv in r) all[kv.Key] = kv.Value;
                onChunk(r);
            }
            finally { gate.Release(); }
        }).ToList();
        await Task.WhenAll(tasks);
        return all;
    }

    async Task<Dictionary<int, string>> ChunkAsync(int[] ids, IReadOnlyList<string> texts, string? source,
        string target, string glossary, bool isRetry, CancellationToken ct)
    {
        var first = ids[0];
        var sourceName = source is null ? "auto-detect (usually Indonesian or English)" : LanguageOption.EnglishName(source);
        var prompt = new StringBuilder($"Source language: {sourceName}\nTarget language: {LanguageOption.EnglishName(target)}\n");
        if (!string.IsNullOrWhiteSpace(glossary)) prompt.Append($"\n<glossary>\n{glossary.Trim()}\n</glossary>\n");
        int ctxStart = Math.Max(0, first - ContextSize);
        if (ctxStart < first)
            prompt.Append("\n<context>\n").Append(string.Join("\n", Enumerable.Range(ctxStart, first - ctxStart).Select(i => texts[i]))).Append("\n</context>\n");
        prompt.Append("\n<segments>\n").Append(string.Join("\n", ids.Select(i => $"[{i}] {texts[i]}"))).Append("\n</segments>");

        var body = new JsonObject
        {
            ["model"] = Model,
            ["max_tokens"] = 16000,
            ["fallbacks"] = "default",
            ["system"] = SystemPrompt,
            ["output_config"] = new JsonObject
            {
                ["effort"] = "medium",
                ["format"] = new JsonObject { ["type"] = "json_schema", ["schema"] = Schema() },
            },
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = prompt.ToString() }),
        };

        var json = await SendAsync(body.ToJsonString(), ct);
        var root = JsonNode.Parse(json)!;
        var stop = root["stop_reason"]?.GetValue<string>();
        if (stop == "refusal") throw new InvalidOperationException("Claude menolak menerjemahkan bagian ini.");
        if (stop == "max_tokens") throw new InvalidOperationException("Jawaban Claude terpotong. Coba lagi.");

        var text = root["content"]?.AsArray().FirstOrDefault(b => b?["type"]?.GetValue<string>() == "text")?["text"]?.GetValue<string>()
            ?? throw new InvalidOperationException("Format jawaban Claude tidak dikenali.");
        var payload = JsonNode.Parse(text)!["translations"]!.AsArray();

        var wanted = ids.ToHashSet();
        var result = new Dictionary<int, string>();
        foreach (var item in payload)
        {
            int id = item!["id"]!.GetValue<int>();
            var t = item["text"]!.GetValue<string>().Trim();
            if (wanted.Contains(id) && t.Length > 0) result[id] = t;
        }

        var missing = ids.Where(i => !result.ContainsKey(i)).ToArray();
        if (missing.Length > 0 && !isRetry)
            foreach (var kv in await ChunkAsync(missing, texts, source, target, glossary, true, ct)) result.TryAdd(kv.Key, kv.Value);
        return result;
    }

    async Task<string> SendAsync(string body, CancellationToken ct)
    {
        for (int attempt = 0; ; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages")
            { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            req.Headers.Add("x-api-key", ApiKey);
            req.Headers.Add("anthropic-version", "2023-06-01");
            req.Headers.Add("anthropic-beta", "server-side-fallback-2026-07-01");
            using var resp = await Http.SendAsync(req, ct);
            var text = await resp.Content.ReadAsStringAsync(ct);
            if (resp.IsSuccessStatusCode) return text;

            int status = (int)resp.StatusCode;
            if ((status == 429 || status >= 500) && attempt < 4)
            {
                double delay = resp.Headers.RetryAfter?.Delta?.TotalSeconds ?? Math.Pow(2, attempt + 1);
                await Task.Delay(TimeSpan.FromSeconds(delay), ct);
                continue;
            }
            string msg;
            try { msg = JsonNode.Parse(text)?["error"]?["message"]?.GetValue<string>() ?? text; } catch { msg = text; }
            throw new InvalidOperationException($"Claude API error {status}: {msg}");
        }
    }
}
