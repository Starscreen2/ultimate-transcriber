using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

namespace TranscribeToText.Core.Services;

public sealed record EngineRunResult(int ExitCode, string StandardOutput, string StandardError);

public sealed class EngineRunner
{
    public async Task<EngineRunResult> RunAsync(
        string executable,
        IEnumerable<string> arguments,
        Action<string>? onOutputLine = null,
        Action<string>? onErrorLine = null,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(executable))
        {
            throw new FileNotFoundException("A required local engine was not found.", executable);
        }

        var start = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(executable) ?? AppContext.BaseDirectory
        };
        foreach (var key in start.Environment.Keys
                     .Where(key => key.StartsWith("LLAMA_ARG_", StringComparison.OrdinalIgnoreCase) ||
                                   key.Equals("LLAMA_API_KEY", StringComparison.OrdinalIgnoreCase)).ToArray())
            start.Environment.Remove(key);
        foreach (var argument in arguments) start.ArgumentList.Add(argument);

        using var process = new Process { StartInfo = start, EnableRaisingEvents = true };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var outputLock = new object();
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        process.OutputDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null) return;
            lock (outputLock) stdout.AppendLine(eventArgs.Data);
            onOutputLine?.Invoke(eventArgs.Data);
        };
        process.ErrorDataReceived += (_, eventArgs) =>
        {
            if (eventArgs.Data is null) return;
            lock (outputLock) stderr.AppendLine(eventArgs.Data);
            onErrorLine?.Invoke(eventArgs.Data);
        };
        process.Exited += (_, _) => completion.TrySetResult();

        cancellationToken.ThrowIfCancellationRequested();
        if (!process.Start()) throw new InvalidOperationException("The local engine could not be started.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var registration = cancellationToken.Register(() =>
        {
            try
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        });

        try
        {
            await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            return new EngineRunResult(process.ExitCode, stdout.ToString(), stderr.ToString());
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
            throw;
        }
    }
}
