namespace AITranscriber;

public class Segment
{
    public double Start { get; init; }
    public double End { get; init; }
    public string Text { get; init; } = "";
    public string? Translation { get; set; }

    public string Clock => Format.Clock(Start);
    public string Display => Translation is null ? Text : Text + "\n→ " + Translation;
}

public record ModelOption(string Id, string Title, string Detail)
{
    public static readonly ModelOption[] All =
    {
        new("tiny", "Tiny", "~75 MB · paling cepat, akurasi rendah"),
        new("base", "Base", "~140 MB · cepat, cukup akurat"),
        new("small", "Small", "~460 MB · seimbang"),
        new("large-v3-turbo", "Large v3 Turbo", "~1,6 GB · paling akurat (disarankan, butuh PC kuat)"),
    };
    public override string ToString() => $"{Title} ({Detail})";
}

public record LanguageOption(string Code, string Name)
{
    public const string Mixed = "id-en";
    public static readonly HashSet<string> IndonesianFamily = new() { "id", "ms", "jw", "su" };

    public static readonly LanguageOption[] All =
    {
        new(Mixed, "Indonesia + Inggris (campuran)"),
        new("id", "Indonesia"), new("en", "Inggris"),
        new("auto", "Deteksi otomatis (semua bahasa)"),
        new("ms", "Melayu"), new("jw", "Jawa"), new("su", "Sunda"),
        new("ar", "Arab"), new("ja", "Jepang"), new("ko", "Korea"), new("zh", "Mandarin"),
        new("es", "Spanyol"), new("fr", "Prancis"), new("de", "Jerman"), new("nl", "Belanda"),
    };

    public static string EnglishName(string code) => code switch
    {
        "id" => "Indonesian", "en" => "English", "ms" => "Malay", "jw" => "Javanese",
        "su" => "Sundanese", "ar" => "Arabic", "ja" => "Japanese", "ko" => "Korean",
        "zh" => "Chinese", "es" => "Spanish", "fr" => "French", "de" => "German",
        "nl" => "Dutch", _ => code,
    };

    public override string ToString() => Name;
}

public enum ExportFormat { Txt, Srt, Vtt, Md }
public enum ExportContent { Original, Translation, Bilingual }

public static class Format
{
    public static string Clock(double seconds)
    {
        int total = Math.Max(0, (int)Math.Floor(seconds));
        int h = total / 3600, m = total / 60 % 60, s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m:00}:{s:00}";
    }
}
