using System.Globalization;
using System.Text;

namespace AITranscriber;

public static class Exporter
{
    public static string Render(IReadOnlyList<Segment> segments, ExportFormat format, ExportContent content, bool timestamps, string title)
    {
        var sb = new StringBuilder();
        switch (format)
        {
            case ExportFormat.Txt:
                var sep = content == ExportContent.Bilingual ? "\n\n" : "\n";
                sb.Append(string.Join(sep, segments.Select(s =>
                {
                    var body = string.Join("\n    ", Lines(s, content));
                    return timestamps ? $"[{Format.Clock(s.Start)}] {body}" : body;
                }))).Append('\n');
                break;
            case ExportFormat.Md:
                sb.Append($"# {title}\n\n");
                sb.Append(string.Join("\n\n", segments.Select(s =>
                {
                    var p = Lines(s, content);
                    var t = timestamps ? $"**[{Format.Clock(s.Start)}]** {p[0]}" : p[0];
                    return p.Count > 1 ? $"{t}  \n*{p[1]}*" : t;
                }))).Append('\n');
                break;
            case ExportFormat.Srt:
                sb.Append(string.Join("\n", segments.Select((s, i) =>
                    $"{i + 1}\n{Stamp(s.Start, ',')} --> {Stamp(s.End, ',')}\n{string.Join("\n", Lines(s, content))}\n")));
                break;
            case ExportFormat.Vtt:
                sb.Append("WEBVTT\n\n");
                sb.Append(string.Join("\n", segments.Select(s =>
                    $"{Stamp(s.Start, '.')} --> {Stamp(s.End, '.')}\n{string.Join("\n", Lines(s, content))}\n")));
                break;
        }
        return sb.ToString();
    }

    static List<string> Lines(Segment s, ExportContent c) => c switch
    {
        ExportContent.Translation => new() { s.Translation ?? s.Text },
        ExportContent.Bilingual => s.Translation is null ? new() { s.Text } : new() { s.Text, s.Translation },
        _ => new() { s.Text },
    };

    public static string Stamp(double seconds, char sep)
    {
        long ms = Math.Max(0, (long)Math.Round(seconds * 1000));
        return string.Create(CultureInfo.InvariantCulture,
            $"{ms / 3_600_000:00}:{ms / 60_000 % 60:00}:{ms / 1000 % 60:00}{sep}{ms % 1000:000}");
    }
}
