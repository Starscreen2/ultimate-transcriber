using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using TranscribeToText.Core.Models;
using TranscribeToText.Core.Services;

namespace TranscribeToText.Windows.Pages;

public sealed partial class SettingsPage : Page
{
    private readonly WindowsAppPaths _paths = new();
    private readonly WindowsAppSettingsStore _settingsStore;
    private readonly ModelDownloadService _downloads = new();
    private readonly List<ModelRow> _rows = [];

    public SettingsPage()
    {
        InitializeComponent();
        _settingsStore = new WindowsAppSettingsStore(_paths);
        var settings = _settingsStore.Load();
        DefaultModelPicker.ItemsSource = ModelCatalog.TranscriptionModels;
        DefaultModelPicker.SelectedItem = ModelCatalog.FindTranscriptionModel(settings.DefaultModelId);
        var savedLanguage = DefaultLanguagePicker.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => (item.Tag as string) == settings.DefaultLanguage);
        DefaultLanguagePicker.SelectedItem = savedLanguage ?? DefaultLanguagePicker.Items[0];
        DefaultLanguageCodeBox.Text = savedLanguage is null && settings.DefaultLanguage != "auto"
            ? settings.DefaultLanguage
            : string.Empty;
        DefaultLanguagePicker.SelectionChanged += (_, _) => DefaultLanguageCodeBox.Text = string.Empty;
        BackendPicker.SelectedItem = BackendPicker.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => (item.Tag as string) == settings.EngineBackend) ?? BackendPicker.Items[0];
        DefaultSpeakerCheckBox.IsChecked = settings.DetectSpeakersByDefault;
        MeetingDetectionCheckBox.IsChecked = settings.MeetingDetectionEnabled;
        BackendPicker.SelectionChanged += (_, _) => UpdateBackendStatus();
        DefaultModelPicker.SelectionChanged += (_, _) => UpdateDefaultLanguageMode();

        foreach (var model in ModelCatalog.All)
        {
            var row = new ModelRow(model, _downloads.IsInstalled(model, _paths));
            _rows.Add(row);
        }
        ModelsList.ItemsSource = _rows;
        UpdateBackendStatus();
        UpdateDefaultLanguageMode();
    }

    private void UpdateBackendStatus()
    {
        var backend = (BackendPicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "cpu";
        var engines = new EnginePaths(backend: backend);
        var selected = backend == "auto"
            ? engines.FindOnBackend("whisper-cli.exe", "cuda") ?? engines.FindOnBackend("whisper-cli.exe", "vulkan") ?? engines.FindOnBackend("whisper-cli.exe", "cpu")
            : engines.FindOnBackend("whisper-cli.exe", backend);
        var cpu = engines.FindOnBackend("whisper-cli.exe", "cpu");
        BackendStatus.Text = selected is not null
            ? $"A {backend.ToUpperInvariant()} Whisper engine is packaged. A GPU engine that fails to start will retry on CPU when the CPU engine is installed."
            : cpu is not null
                ? "The selected GPU engine is not packaged. Transcription will fall back to the CPU engine."
                : "No Whisper engine is packaged yet. Build and install the CPU engine bundle first.";
    }

    private void UpdateDefaultLanguageMode()
    {
        var englishOnly = (DefaultModelPicker.SelectedItem as ModelDefinition)?.Id
            .EndsWith(".en", StringComparison.OrdinalIgnoreCase) == true;
        DefaultLanguagePicker.IsEnabled = !englishOnly;
        DefaultLanguageCodeBox.IsEnabled = !englishOnly;
        DefaultLanguageModeHint.Text = englishOnly ? "This English-only model always transcribes in English." : string.Empty;
    }

    private void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        var backend = (BackendPicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "cpu";
        var language = string.IsNullOrWhiteSpace(DefaultLanguageCodeBox.Text)
            ? (DefaultLanguagePicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "auto"
            : DefaultLanguageCodeBox.Text.Trim();
        var model = DefaultModelPicker.SelectedItem as ModelDefinition
            ?? ModelCatalog.FindTranscriptionModel("large-v3-turbo");
        var prior = _settingsStore.Load();
        _settingsStore.Save(prior with
        {
            EngineBackend = backend,
            DefaultModelId = model.Id,
            DefaultLanguage = language,
            DetectSpeakersByDefault = DefaultSpeakerCheckBox.IsChecked == true,
            MeetingDetectionEnabled = MeetingDetectionCheckBox.IsChecked == true
        });
        ModelStatus.Text = "Settings saved on this PC.";
        UpdateBackendStatus();
    }

    private async void DownloadModel_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not string id) return;
        var row = _rows.FirstOrDefault(candidate => candidate.Id == id);
        var model = ModelCatalog.All.FirstOrDefault(candidate => candidate.Id == id);
        if (row is null || model is null) return;

        ModelProgress.Visibility = Visibility.Visible;
        ModelProgress.IsIndeterminate = true;
        ModelStatus.Text = $"Downloading {model.Name}…";
        foreach (var item in _rows) item.IsEnabled = false;
        try
        {
            var progress = new Progress<DownloadProgress>(value =>
            {
                if (value.Fraction is double fraction)
                {
                    ModelProgress.IsIndeterminate = false;
                    ModelProgress.Value = fraction * 100;
                    ModelStatus.Text = $"Downloading {model.Name}… {fraction:P0}";
                }
            });
            await _downloads.EnsureInstalledAsync(model, _paths, progress);
            row.Status = "Installed";
            ModelStatus.Text = $"{model.Name} is ready. Stored in {_paths.PathFor(model)}";
        }
        catch (Exception error)
        {
            ModelStatus.Text = error.Message;
        }
        finally
        {
            foreach (var item in _rows) item.IsEnabled = true;
            ModelProgress.Visibility = Visibility.Collapsed;
            ModelProgress.IsIndeterminate = false;
            ModelProgress.Value = 0;
        }
    }
}

public sealed class ModelRow : INotifyPropertyChanged
{
    private string _status;
    private bool _isEnabled = true;

    public event PropertyChangedEventHandler? PropertyChanged;
    public string Id { get; }
    public string Name { get; }
    public string Description { get; }
    public string Status { get => _status; set { _status = value; OnPropertyChanged(); } }
    public bool IsEnabled { get => _isEnabled; set { _isEnabled = value; OnPropertyChanged(); } }

    public ModelRow(ModelDefinition model, bool installed)
    {
        Id = model.Id;
        Name = model.Name;
        Description = model.Description;
        _status = installed ? "Installed" : "Not downloaded";
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
