using System.Text.Json;
using TranscribeToText.Core.Models;

namespace TranscribeToText.Core.Services;

public sealed class WorkspaceLibraryStore
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _filePath;
    private readonly JsonSerializerOptions _jsonOptions = TranscriptJson.CreateOptions(indented: true);
    private List<WorkspaceLibraryEntry> _entries = [];
    private string? _loadFailure;

    public WorkspaceLibraryStore(string? filePath = null)
    {
        _filePath = filePath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TranscribeToText", "library", "transcriptions.json");

        if (!File.Exists(_filePath)) return;

        try
        {
            _entries = JsonSerializer.Deserialize<List<WorkspaceLibraryEntry>>(
                File.ReadAllBytes(_filePath), _jsonOptions) ?? [];
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            _entries = [];
            _loadFailure = error.Message;
        }
    }

    public string? LoadFailure => _loadFailure;

    public async Task<IReadOnlyList<WorkspaceLibraryEntry>> SnapshotAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return _entries.OrderByDescending(entry => entry.UpdatedAt).ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveAsync(WorkspaceLibraryEntry entry, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(entry);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureWritable();
            var updated = _entries.ToList();
            var index = updated.FindIndex(candidate => candidate.Id == entry.Id);
            if (index >= 0) updated[index] = entry with { UpdatedAt = DateTimeOffset.UtcNow };
            else updated.Add(entry);
            await PersistAsync(updated, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task MarkDeletedAsync(Guid id, CancellationToken cancellationToken = default) =>
        UpdateAsync(id, entry => entry with { IsDeleted = true }, cancellationToken);

    public Task RestoreAsync(Guid id, CancellationToken cancellationToken = default) =>
        UpdateAsync(id, entry => entry with { IsDeleted = false }, cancellationToken);

    public async Task PermanentlyDeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureWritable();
            await PersistAsync(_entries.Where(entry => entry.Id != id).ToList(), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task ClearRecentlyDeletedAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureWritable();
            await PersistAsync(_entries.Where(entry => !entry.IsDeleted).ToList(), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task UpdateAsync(
        Guid id,
        Func<WorkspaceLibraryEntry, WorkspaceLibraryEntry> change,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            EnsureWritable();
            var updated = _entries.ToList();
            var index = updated.FindIndex(entry => entry.Id == id);
            if (index < 0) return;
            updated[index] = change(updated[index]) with { UpdatedAt = DateTimeOffset.UtcNow };
            await PersistAsync(updated, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private void EnsureWritable()
    {
        if (_loadFailure is not null)
        {
            throw new InvalidOperationException(
                $"The transcript library could not be read ({_loadFailure}). The existing file was left untouched; repair it before saving changes.");
        }
    }

    private async Task PersistAsync(List<WorkspaceLibraryEntry> updated, CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new InvalidOperationException("The library file path has no parent directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = _filePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(updated, _jsonOptions);
            await using (var stream = new FileStream(
                temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                16 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporaryPath, _filePath, overwrite: true);
            _entries = updated;
        }
        finally
        {
            try { File.Delete(temporaryPath); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
