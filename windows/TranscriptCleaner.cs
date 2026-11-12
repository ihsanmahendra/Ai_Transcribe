using System.Text.RegularExpressions;

namespace AITranscriber;

/// Membersihkan "halusinasi" khas Whisper: pengulangan kata, segmen kembar,
/// dan kalimat karangan pada bagian hening/musik.
public static class TranscriptCleaner
{
    public record RawSegment(double Start, double End, string Text, float AvgLogprob, float NoSpeechProb, float CompressionRatio);

    static readonly HashSet<string> Hallucinations = new()
    {
        "terima kasih telah menonton", "terima kasih sudah menonton", "terima kasih",
        "sampai jumpa di video berikutnya", "sampai jumpa", "jangan lupa like dan subscribe",
        "jangan lupa subscribe", "silakan subscribe", "subtitle by", "subtitle oleh",
        "thanks for watching", "thank you for watching", "thank you",
        "please subscribe", "like and subscribe", "subtitles by the amara org community",
        "terjemahan oleh", "diterjemahkan oleh",
    };

    public static List<Segment> Clean(IEnumerable<RawSegment> raw)
    {
        var result = new List<Segment>();
        var previousKey = "";
        foreach (var seg in raw.OrderBy(s => s.Start))
        {
            var text = CollapseRepeats(StripSpecialTokens(seg.Text));
            if (text.Length == 0) continue;
            var key = Normalize(text);
            if (key.Length == 0) continue;

            if (seg.NoSpeechProb > 0.5 && seg.AvgLogprob < -0.8) continue;
            if (Hallucinations.Contains(key) && (seg.AvgLogprob < -0.4 || seg.NoSpeechProb > 0.2)) continue;
            if (seg.CompressionRatio > 2.4 && seg.AvgLogprob < -1.0) continue;
            if (key == previousKey) continue;

            previousKey = key;
            result.Add(new Segment { Start = seg.Start, End = seg.End, Text = text });
        }
        return result;
    }

    public static string StripSpecialTokens(string text) =>
        Regex.Replace(text, @"<\|[^|]*\|>|\[_[A-Z]+_[^\]]*\]", "").Trim();

    /// Frasa yang diulang 3x atau lebih berturut-turut dipangkas menjadi satu.
    public static string CollapseRepeats(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count < 3) return text;

        for (int n = Math.Min(8, words.Count / 3); n >= 1; n--)
        {
            int i = 0;
            while (i + n * 3 <= words.Count)
            {
                var phrase = words.GetRange(i, n).Select(Normalize).ToList();
                int repeats = 1;
                while (i + n * (repeats + 1) <= words.Count &&
                       words.GetRange(i + n * repeats, n).Select(Normalize).SequenceEqual(phrase))
                    repeats++;
                if (repeats >= 3) words.RemoveRange(i + n, n * (repeats - 1));
                i++;
            }
        }
        return string.Join(" ", words);
    }

    public static string Normalize(string text) =>
        string.Join(" ", Regex.Split(text.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(s => s.Length > 0));
}
