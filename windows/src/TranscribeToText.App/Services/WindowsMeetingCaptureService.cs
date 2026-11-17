using NAudio.Wave;
using TranscribeToText.Core.Services;

namespace TranscribeToText.Windows.Services;

public sealed class WindowsMeetingCaptureService
{
    public static WindowsMeetingCaptureService Shared { get; } = new();

    private CaptureTrack? _microphone;
    private CaptureTrack? _systemAudio;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public bool IsRecording => _microphone is not null || _systemAudio is not null;
    public string? SessionFolder { get; private set; }
    public DateTimeOffset? StartedAt { get; private set; }

    public async Task StartAsync(string sessionFolder, bool microphone, bool systemAudio)
    {
        if (!microphone && !systemAudio)
            throw new InvalidOperationException("Select a microphone or system audio source before recording.");

        await _gate.WaitAsync();
        try
        {
            if (IsRecording) throw new InvalidOperationException("A meeting recording is already active.");
            Directory.CreateDirectory(sessionFolder);
            SessionFolder = sessionFolder;
            StartedAt = DateTimeOffset.UtcNow;
            if (microphone)
                _microphone = StartTrack(Path.Combine(sessionFolder, "microphone.wav"), loopback: false);
            try
            {
                if (systemAudio)
                    _systemAudio = StartTrack(Path.Combine(sessionFolder, "system-audio.wav"), loopback: true);
            }
            catch
            {
                if (_microphone is not null) await StopTrackAsync(_microphone);
                _microphone = null;
                throw;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> StopAndMixAsync(string ffmpegPath, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (!IsRecording || string.IsNullOrWhiteSpace(SessionFolder))
                throw new InvalidOperationException("There is no active meeting recording.");
            var folder = SessionFolder;
            var tracks = new[] { _microphone, _systemAudio }.Where(track => track is not null).Cast<CaptureTrack>().ToArray();
            _microphone = null;
            _systemAudio = null;
            if (tracks.Length > 0) StartedAt = null;
            Exception? stopError = null;
            foreach (var track in tracks)
            {
                try { await StopTrackAsync(track).WaitAsync(cancellationToken); }
                catch (Exception error) { stopError ??= error; }
            }
            if (stopError is not null)
                throw new InvalidOperationException("One of the meeting audio sources could not be closed cleanly. The original tracks remain in the recording folder.", stopError);

            var usableTracks = tracks.Where(track => File.Exists(track.Path) && new FileInfo(track.Path).Length > 128).ToArray();
            if (usableTracks.Length == 0)
                throw new InvalidOperationException("No audio was captured. The original track files were kept for recovery.");

            var output = Path.Combine(folder, "meeting-audio.m4a");
            var arguments = new List<string> { "-hide_banner", "-loglevel", "error", "-y" };
            foreach (var track in usableTracks) arguments.AddRange(["-i", track.Path]);
            if (usableTracks.Length == 1)
            {
                arguments.AddRange(["-map", "0:a:0", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", output]);
            }
            else
            {
                var sources = string.Concat(Enumerable.Range(0, usableTracks.Length).Select(index => $"[{index}:a]"));
                arguments.AddRange(["-filter_complex", $"{sources}amix=inputs={usableTracks.Length}:duration=longest:dropout_transition=0[audio]",
                    "-map", "[audio]", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", output]);
            }
            var result = await new EngineRunner().RunAsync(ffmpegPath, arguments, cancellationToken: cancellationToken);
            if (result.ExitCode != 0 || !File.Exists(output))
                throw new InvalidOperationException("FFmpeg could not combine the meeting audio tracks." + Environment.NewLine + result.StandardError);
            return output;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task StopAndPreserveTracksAsync()
    {
        await _gate.WaitAsync();
        try
        {
            var tracks = new[] { _microphone, _systemAudio }.Where(track => track is not null).Cast<CaptureTrack>().ToArray();
            _microphone = null;
            _systemAudio = null;
            if (tracks.Length > 0) StartedAt = null;
            foreach (var track in tracks)
            {
                try { await StopTrackAsync(track); }
                catch { }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private static CaptureTrack StartTrack(string path, bool loopback)
    {
        var recorder = loopback
            ? new WasapiRecorderBuilder().WithLoopbackCapture().Build()
            : new WasapiRecorderBuilder().Build();
        var writer = new WaveFileWriter(path, recorder.WaveFormat);
        var track = new CaptureTrack(path, recorder, writer);
        recorder.DataAvailable += (buffer, _, _, _) =>
        {
            lock (track.WriterGate) track.Writer?.Write(buffer);
        };
        recorder.RecordingStopped += (_, eventArgs) =>
        {
            lock (track.WriterGate)
            {
                track.Writer?.Dispose();
                track.Writer = null;
            }
            track.Stopped.TrySetResult(eventArgs.Exception);
        };
        try
        {
            recorder.StartRecording();
        }
        catch
        {
            track.Writer?.Dispose();
            track.Writer = null;
            recorder.Dispose();
            throw;
        }
        return track;
    }

    private static async Task StopTrackAsync(CaptureTrack track)
    {
        try
        {
            if (!track.Stopped.Task.IsCompleted) track.Recorder.StopRecording();
            var error = await track.Stopped.Task.WaitAsync(TimeSpan.FromSeconds(15));
            if (error is not null) throw new InvalidOperationException("An audio source stopped unexpectedly.", error);
        }
        finally
        {
            track.Recorder.Dispose();
            lock (track.WriterGate)
            {
                track.Writer?.Dispose();
                track.Writer = null;
            }
        }
    }

    private sealed class CaptureTrack(string path, WasapiRecorder recorder, WaveFileWriter writer)
    {
        public string Path { get; } = path;
        public WasapiRecorder Recorder { get; } = recorder;
        public WaveFileWriter? Writer { get; set; } = writer;
        public object WriterGate { get; } = new();
        public TaskCompletionSource<Exception?> Stopped { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}
