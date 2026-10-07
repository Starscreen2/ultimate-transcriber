#!/usr/bin/env python3
"""Exercise the production live-worker pipe/lifecycle code with small fake engines."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
source = (ROOT / "MeetingCapture.swift").read_text()
worker = source[source.index("private final class LiveWhisperWorker:"):source.index("final class MeetingCaptureController:")]
prelude = r'''
import Foundation
import Darwin
struct TranscriptSegment { var start: Double; var end: Double; var text: String; var speakerID: Int? }
enum AppError: LocalizedError { case message(String), cancelled
    var errorDescription: String? { switch self { case .message(let message): return message; case .cancelled: return "Cancelled" } }
}
final class OperationControl: @unchecked Sendable {
    let lock = NSLock(); var cancelled = false; var process: Process?
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw AppError.cancelled } }
    func attach(_ process: Process) { lock.lock(); self.process = process; let stop = cancelled; lock.unlock(); if stop { process.terminate() } }
    func detach(_ process: Process) { lock.lock(); if self.process === process { self.process = nil }; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; let process = process; lock.unlock(); process?.terminate() }
}
'''
harness = r'''
@main struct WorkerTests {
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw AppError.message(message) } }
    static func script(_ name: String, _ contents: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try ("#!/bin/sh\n" + contents).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("unused.bin")
        let normal = try script("normal", "printf '{\"type\":\"ready\"}\\n'\ncat >/dev/null\nprintf '{\"type\":\"segment\",\"start\":-1,\"end\":1,\"text\":\"invalid negative\"}\\n{\"type\":\"segment\",\"start\":2,\"end\":1,\"text\":\"invalid reversed\"}\\n{\"type\":\"segment\",\"start\":0,\"end\":1,\"text\":\" hello \"}\\n{\"type\":\"finished\"}'\n", in: folder)
        let worker = LiveWhisperWorker { _ in }
        try worker.start(executable: normal, model: model)
        worker.append(Array(repeating: 0.1, count: 80_000))
        let segments = await worker.finish(timeout: 3)
        try require(segments.count == 1 && segments[0].text == "hello", "Final JSON line or pending input was lost")
        try require(worker.failureWarning == nil, "Normal finish incorrectly warned: \(worker.failureWarning ?? "")")
        let repeated = await worker.finish(timeout: 1)
        try require(repeated.count == 1, "Repeated finish did not return the saved segments")

        let early = try script("early", "exit 7\n", in: folder)
        let failed = LiveWhisperWorker { _ in }
        let earlyStart = Date()
        var earlyFailed = false
        do { try failed.start(executable: early, model: model) }
        catch { earlyFailed = true }
        try require(earlyFailed, "An engine that exited before readiness succeeded")
        try require(Date().timeIntervalSince(earlyStart) < 3, "Early engine exit waited for the 120-second ready timeout")
        let missing = LiveWhisperWorker { _ in }
        var missingFailed = false
        do { try missing.start(executable: folder.appendingPathComponent("missing"), model: model) }
        catch { missingFailed = true }
        try require(missingFailed, "Missing executable succeeded")

        let closesStdin = try script("closes-stdin", "printf '{\"type\":\"ready\"}\\n'\ndd bs=1 count=1 >/dev/null 2>/dev/null\nexit 0\n", in: folder)
        let brokenPipe = LiveWhisperWorker { _ in }
        try brokenPipe.start(executable: closesStdin, model: model)
        brokenPipe.append(Array(repeating: 0.25, count: 1_000_000))
        _ = await brokenPipe.finish(timeout: 3)
        try require(brokenPipe.failureWarning != nil, "A broken input stream had no warning")

        let hangs = try script("hangs", "trap '' TERM\nprintf '{\"type\":\"ready\"}\\n'\nwhile :; do :; done\n", in: folder)
        let hung = LiveWhisperWorker { _ in }
        try hung.start(executable: hangs, model: model)
        hung.append(Array(repeating: 0.25, count: 1_000_000))
        let finishStart = Date()
        _ = await hung.finish(timeout: 0.25)
        try require(Date().timeIntervalSince(finishStart) < 5, "A blocked input write hung finalization")
        try require(hung.failureWarning?.contains("preserved") == true, "The forced finish did not warn that audio was preserved")

        var backlogWarnings = 0
        let overloaded = LiveWhisperWorker(onWarning: { _ in backlogWarnings += 1 }) { _ in }
        try overloaded.start(executable: hangs, model: model)
        // Each packet contains two seconds of PCM. The fake engine never reads;
        // filling the queue must warn exactly once rather than growing forever.
        let packet = Array(repeating: Float(0.1), count: 32_000)
        for _ in 0..<100 { overloaded.append(packet) }
        try require(overloaded.failureWarning?.contains("fell behind") == true, "A stalled worker queued unbounded PCM")
        overloaded.append(packet)
        _ = await overloaded.finish(timeout: 0.1)
        try require(backlogWarnings == 1, "Backlog warning repeated or never reached the UI")

        let loading = try script("loading", "while :; do :; done\n", in: folder)
        let control = OperationControl()
        let cancelled = LiveWhisperWorker { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { control.cancel() }
        var cancelledFailed = false
        do { try cancelled.start(executable: loading, model: model, control: control) }
        catch { cancelledFailed = true }
        try require(cancelledFailed && control.cancelled, "Cancelled loading did not release the ready wait")
        print("Live-worker regression checks passed (normal, repeated finish, early exit, EPIPE, hung pipe, bounded backlog, cancelled loading).")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="meeting-worker-tests-") as directory:
    path = pathlib.Path(directory)
    swift_file = path / "WorkerTests.swift"
    swift_file.write_text(prelude + worker + harness)
    binary = path / "worker-tests"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(swift_file), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
