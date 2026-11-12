using System.Collections.ObjectModel;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using NAudio.Wave;

namespace AITranscriber;

public partial class MainWindow : Window
{
    static readonly string[] Extensions = { ".mp3", ".m4a", ".wav", ".flac", ".aac", ".mp4", ".mov", ".mkv", ".ogg", ".wma" };
    static string SettingsPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AITranscriber", "settings.json");

    readonly ObservableCollection<Segment> view = new();
    List<Segment> segments = new();
    string? file;
    double duration;
    string? detectedLanguage;
    CancellationTokenSource? cts;
    WaveOutEvent? player;
    AudioFileReader? playerReader;

    record Target(string Code, string Name) { public override string ToString() => Name; }

    public MainWindow()
    {
        InitializeComponent();
        ModelBox.ItemsSource = ModelOption.All;
        LangBox.ItemsSource = LanguageOption.All;
        TargetBox.ItemsSource = new[] { new Target("en", "Ke Inggris"), new Target("id", "Ke Indonesia") };
        TargetBox.SelectedIndex = 0;
        List.ItemsSource = view;
        LoadSettings();
        KeyBox.Password = SecretStore.Get() ?? "";
        Closing += (_, _) => { SaveSettings(); StopPlayback(); cts?.Cancel(); };
    }

    // ---------- Pengaturan ----------
    record Settings(string? Model, string? Language, string? Vocabulary);

    void LoadSettings()
    {
        Settings? s = null;
        try { s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath)); } catch { }
        ModelBox.SelectedItem = ModelOption.All.FirstOrDefault(m => m.Id == s?.Model) ?? ModelOption.All[2];
        LangBox.SelectedItem = LanguageOption.All.FirstOrDefault(l => l.Code == s?.Language) ?? LanguageOption.All[0];
        VocabBox.Text = s?.Vocabulary ?? "";
    }

    void SaveSettings()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new Settings(
                ((ModelOption)ModelBox.SelectedItem).Id, ((LanguageOption)LangBox.SelectedItem).Code, VocabBox.Text)));
        }
        catch { }
    }

    // ---------- File ----------
    void OnOpen(object s, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Filter = "Audio/Video|" + string.Join(";", Extensions.Select(x => "*" + x)) + "|Semua file|*.*",
        };
        if (dlg.ShowDialog() == true) SetFile(dlg.FileName);
    }

    void OnDrop(object s, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } f) SetFile(f[0]);
    }

    void SetFile(string path)
    {
        if (cts is not null) return;
        file = path;
        try { duration = Transcriber.Duration(path); }
        catch (Exception ex) { MessageBox.Show("File tidak bisa dibaca: " + ex.Message); file = null; return; }
        FileLabel.Text = $"{System.IO.Path.GetFileName(path)} · {Format.Clock(duration)}";
        StartBtn.IsEnabled = true;
        segments = new(); view.Clear();
        UpdateButtons();
        StopPlayback();
    }

    // ---------- Transkripsi ----------
    async void OnStart(object s, RoutedEventArgs e)
    {
        if (file is null || cts is not null) return;
        SaveSettings();
        cts = new CancellationTokenSource();
        StartBtn.IsEnabled = false; CancelBtn.IsEnabled = true; OpenBtn.IsEnabled = false;
        segments = new(); view.Clear(); UpdateButtons();
        Progress.Value = 0;
        var began = DateTime.Now;
        var model = (ModelOption)ModelBox.SelectedItem;
        var opt = new TranscribeOptions(model.Id, ((LanguageOption)LangBox.SelectedItem).Code, VocabBox.Text);

        try
        {
            if (!File.Exists(Transcriber.ModelPath(model.Id)))
            {
                StatusLabel.Text = $"Mengunduh model {model.Title}…";
                await Transcriber.EnsureModelAsync(model.Id,
                    new Progress<double>(p => { Progress.Value = p; StatusLabel.Text = $"Mengunduh model {model.Title}… {p:P0}"; }), cts.Token);
            }
            Progress.Value = 0;
            var (result, lang) = await Task.Run(() => Transcriber.RunAsync(file, opt, duration,
                st => Dispatcher.Invoke(() => StatusLabel.Text = st),
                (frac, text) => Dispatcher.Invoke(() =>
                {
                    Progress.Value = frac;
                    LiveLabel.Text = text;
                    var left = (DateTime.Now - began).TotalSeconds / Math.Max(frac, 0.01) * (1 - frac);
                    StatusLabel.Text = $"Mentranskripsi… {frac:P0}" + (frac > 0.03 ? $" · sisa ±{Format.Clock(left)}" : "");
                }), cts.Token));

            segments = result; detectedLanguage = lang;
            ApplyFilter();
            Progress.Value = 1;
            LiveLabel.Text = "";
            TargetBox.SelectedIndex = lang is not null && LanguageOption.IndonesianFamily.Contains(lang) ? 0 : 1;
            StatusLabel.Text = $"Selesai dalam {Format.Clock((DateTime.Now - began).TotalSeconds)} · bahasa: {lang ?? "?"} · {segments.Count} segmen";
        }
        catch (OperationCanceledException) { StatusLabel.Text = "Dibatalkan."; LiveLabel.Text = ""; }
        catch (Exception ex) { StatusLabel.Text = "Gagal: " + ex.Message; LiveLabel.Text = ""; }
        finally
        {
            cts?.Dispose(); cts = null;
            StartBtn.IsEnabled = true; CancelBtn.IsEnabled = false; OpenBtn.IsEnabled = true;
            UpdateButtons();
        }
    }

    void OnCancel(object s, RoutedEventArgs e) => cts?.Cancel();

    // ---------- Terjemahan ----------
    void OnSaveKey(object s, RoutedEventArgs e)
    {
        SecretStore.Set(KeyBox.Password);
        StatusLabel.Text = "API key disimpan (terenkripsi).";
    }

    void OnRemoveKey(object s, RoutedEventArgs e)
    {
        SecretStore.Set(null); KeyBox.Password = "";
        StatusLabel.Text = "API key dihapus.";
    }

    async void OnTranslate(object s, RoutedEventArgs e)
    {
        var key = KeyBox.Password.Trim();
        if (key.Length == 0) { MessageBox.Show("Isi API key Claude dulu (console.anthropic.com/settings/keys)."); return; }
        if (cts is not null || segments.Count == 0) return;

        cts = new CancellationTokenSource();
        CancelBtn.IsEnabled = true; TranslateBtn.IsEnabled = false;
        var target = ((Target)TargetBox.SelectedItem).Code;
        var texts = segments.Select(x => x.Text).ToList();
        var pending = Enumerable.Range(0, segments.Count).Where(i => segments[i].Translation is null).ToList();
        int done = 0;
        try
        {
            StatusLabel.Text = $"Menerjemahkan 0/{pending.Count}…";
            var tr = new ClaudeTranslator { ApiKey = key };
            await tr.TranslateAsync(texts, pending, detectedLanguage, target, VocabBox.Text,
                chunk => Dispatcher.Invoke(() =>
                {
                    foreach (var kv in chunk) segments[kv.Key].Translation = kv.Value;
                    done += chunk.Count;
                    StatusLabel.Text = $"Menerjemahkan {done}/{pending.Count}…";
                    ApplyFilter();
                }), cts.Token);
            StatusLabel.Text = "Terjemahan selesai.";
        }
        catch (OperationCanceledException) { StatusLabel.Text = "Terjemahan dibatalkan."; }
        catch (Exception ex) { StatusLabel.Text = "Terjemahan gagal: " + ex.Message; }
        finally { cts?.Dispose(); cts = null; CancelBtn.IsEnabled = false; UpdateButtons(); }
    }

    // ---------- Daftar, cari, putar ----------
    void ApplyFilter()
    {
        var q = SearchBox.Text.Trim();
        view.Clear();
        foreach (var seg in segments)
            if (q.Length == 0 || seg.Text.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                || (seg.Translation?.Contains(q, StringComparison.CurrentCultureIgnoreCase) ?? false))
                view.Add(seg);
        UpdateButtons();
    }

    void OnSearch(object s, TextChangedEventArgs e) => ApplyFilter();
    void OnStampChanged(object s, RoutedEventArgs e) { }

    void UpdateButtons()
    {
        bool has = segments.Count > 0;
        ExportBtn.IsEnabled = CopyBtn.IsEnabled = has;
        TranslateBtn.IsEnabled = has && cts is null;
    }

    void OnSegmentPlay(object s, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (List.SelectedItem is not Segment seg || file is null) return;
        try
        {
            StopPlayback();
            playerReader = new AudioFileReader(file) { CurrentTime = TimeSpan.FromSeconds(seg.Start) };
            player = new WaveOutEvent();
            player.Init(playerReader);
            player.Play();
        }
        catch (Exception ex) { StatusLabel.Text = "Tidak bisa memutar: " + ex.Message; }
    }

    void StopPlayback()
    {
        player?.Dispose(); playerReader?.Dispose();
        player = null; playerReader = null;
    }

    // ---------- Ekspor ----------
    bool HasTranslation => segments.Any(x => x.Translation is not null);

    void OnCopy(object s, RoutedEventArgs e)
    {
        var content = HasTranslation ? ExportContent.Bilingual : ExportContent.Original;
        Clipboard.SetText(Exporter.Render(segments, ExportFormat.Txt, content, StampBox.IsChecked == true, "Transkrip"));
        StatusLabel.Text = "Transkrip disalin.";
    }

    void OnExport(object s, RoutedEventArgs e)
    {
        var content = ExportContent.Original;
        if (HasTranslation)
        {
            var r = MessageBox.Show("Sertakan terjemahan?\n\nYa = dwibahasa\nTidak = hanya teks asli\nBatal = hanya terjemahan",
                "Ekspor", MessageBoxButton.YesNoCancel);
            content = r == MessageBoxResult.Yes ? ExportContent.Bilingual
                    : r == MessageBoxResult.No ? ExportContent.Original : ExportContent.Translation;
        }

        var baseName = System.IO.Path.GetFileNameWithoutExtension(file ?? "transkrip");
        if (content == ExportContent.Translation) baseName += "-terjemahan";
        if (content == ExportContent.Bilingual) baseName += "-dwibahasa";

        var dlg = new SaveFileDialog
        {
            FileName = baseName,
            Filter = "Teks (.txt)|*.txt|SubRip (.srt)|*.srt|WebVTT (.vtt)|*.vtt|Markdown (.md)|*.md",
        };
        if (dlg.ShowDialog() != true) return;
        var format = dlg.FilterIndex switch { 2 => ExportFormat.Srt, 3 => ExportFormat.Vtt, 4 => ExportFormat.Md, _ => ExportFormat.Txt };
        File.WriteAllText(dlg.FileName,
            Exporter.Render(segments, format, content, StampBox.IsChecked == true, baseName),
            new System.Text.UTF8Encoding(false));
        StatusLabel.Text = "Tersimpan: " + dlg.FileName;
    }
}
