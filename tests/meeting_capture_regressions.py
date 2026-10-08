#!/usr/bin/env python3
"""Fault-inject synthetic PCM into the production capture controller, without devices."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Swift private members are available to same-file extensions. Keep test-only
# injection out of the app by compiling this harness appended to its source.
harness = r'''
extension MeetingCaptureController {
    static func verifyPermissionReuse() async throws {
        var prompts = 0
        let request: (@escaping @Sendable (Bool) -> Void) -> Void = { callback in prompts += 1; callback(true) }
        guard await requestMicrophonePermission(status: .notDetermined, requestAccess: request), prompts == 1 else {
            throw AppError.message("Initial microphone request did not complete")
        }
        for _ in 0..<20 {
            guard await requestMicrophonePermission(status: .authorized, requestAccess: request) else {
                throw AppError.message("An existing microphone grant was ignored")
            }
        }
        for status in [AVAuthorizationStatus.denied, .restricted] {
            guard !(await requestMicrophonePermission(status: status, requestAccess: request)) else {
                throw AppError.message("Revoked microphone access was reused")
            }
        }
        guard prompts == 1 else { throw AppError.message("Subsequent recordings repeated the permission request") }
    }
    func injectSources(folder: URL, engine: URL, twoSources: Bool) throws {
        resetSessionTimeline()
        let sessionID = UUID()
        self.sessionID = sessionID
        sessionFolder = folder
        for source in twoSources ? [MeetingAudioSource.microphone, .system] : [.microphone] {
            let worker = LiveWhisperWorker { [weak self] segment in
                self?.receive(segment, source: source, sessionID: sessionID)
            }
            try worker.start(executable: engine, model: folder.appendingPathComponent("unused.bin"))
            let url = source == .microphone ? folder.appendingPathComponent("missing/input.caf") : folder.appendingPathComponent("system.caf")
            installSourceState(MeetingAudioSourceState(sessionID: sessionID, source: source,
                                                       recordingURL: url, worker: worker))
        }
        updateState(active: true, starting: false, stopping: false)
    }
    func rejectInjectedStartup() async {
        updateState(active: false, starting: true, stopping: false)
        await cleanupAfterFailedStart()
        updateState(active: false, starting: false, stopping: false)
    }
    fileprivate func injectBuffer(source: MeetingAudioSource, rate: Double = 16_000) {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.1 }
        guard let state = allSourceStates()[source] else { return }
        captureQueue.sync { consume(buffer, for: state, capturedAt: 10) }
    }
}
@main struct CaptureFailureTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
    static func main() throws {
        let permissionDone = DispatchSemaphore(value: 0)
        var permissionError: Error?
        Task {
            do { try await MeetingCaptureController.verifyPermissionReuse() }
            catch { permissionError = error }
            permissionDone.signal()
        }
        while permissionDone.wait(timeout: .now()) != .success { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if let permissionError { throw permissionError }
        print("Recording permission regressions passed (first request, 20 grant reuses, denial and restriction without re-prompting).")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-faults-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = root.appendingPathComponent("engine")
        try "#!/bin/sh\nprintf '{\"type\":\"ready\"}\\n'\ncat >/dev/null\nprintf '{\"type\":\"segment\",\"start\":0,\"end\":0.1,\"text\":\"Recovered speech\"}\\n{\"type\":\"finished\"}\\n'\n".write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        for twoSources in [false, true] {
            let folder = root.appendingPathComponent(twoSources ? "two-sources" : "one-source")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let controller = MeetingCaptureController()
            let lock = NSLock()
            var done = false
            var result: MeetingSessionResult?
            var failure: String?
            var warnings: [String] = []
            controller.onStatus = { _, message in
                if message.contains("recording stopped") { lock.withLock { warnings.append(message) } }
            }
            controller.onFinished = { value in lock.withLock { result = value; done = true } }
            controller.onFailure = { _, message, _ in lock.withLock { failure = message; done = true } }
            try controller.injectSources(folder: folder, engine: engine, twoSources: twoSources)
            controller.injectBuffer(source: .microphone)
            let firstWarningCount = lock.withLock { warnings.count }
            controller.injectBuffer(source: .microphone)
            try require(lock.withLock { warnings.count } == firstWarningCount && firstWarningCount == 1, "Failed source retried silently or warning repeated")
            if twoSources {
                try require(controller.inProgress, "One failed source stopped a healthy recording source")
                controller.injectBuffer(source: .system)
                try require(controller.inProgress, "Healthy synthetic audio did not keep recording")
                controller.injectBuffer(source: .system, rate: 44_100)
            }
            let deadline = Date().addingTimeInterval(6)
            while !lock.withLock({ done }), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard lock.withLock({ done }) else { controller.stop(); throw AppError.message("Losing every source left the app recording indefinitely") }
            try require(!controller.inProgress, "Failed-source finalization retained an active recording")
            if twoSources {
                try require(result?.speakerWarning?.contains("changed format") == true && failure == nil, "Format failure discarded the healthy audio or warning")
            } else {
                try require(failure?.contains("Microphone recording stopped") == true, "Finalization hid the original capture error")
            }
            let transcript = try String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
            try require(transcript.contains("Recovered speech"), "Capture failure lost the finished worker transcript")
        }
        let startupFolder = root.appendingPathComponent("cancelled-startup")
        try FileManager.default.createDirectory(at: startupFolder, withIntermediateDirectories: true)
        let startup = MeetingCaptureController()
        try startup.injectSources(folder: startupFolder, engine: engine, twoSources: true)
        startup.injectBuffer(source: .system)
        let completed = DispatchSemaphore(value: 0)
        Task { await startup.rejectInjectedStartup(); completed.signal() }
        let deadline = Date().addingTimeInterval(6)
        var cleaned = false
        while Date() < deadline {
            if completed.wait(timeout: .now()) == .success { cleaned = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try require(cleaned && !startup.inProgress, "Cancelled startup did not clean up")
        let recovered = try String(contentsOf: startupFolder.appendingPathComponent("transcript.txt"), encoding: .utf8)
        try require(recovered.contains("Recovered speech"), "Cancelled startup discarded captured speech")
        try require(FileManager.default.fileExists(atPath: startupFolder.appendingPathComponent("system.caf").path), "Cancelled startup discarded captured audio")
        print("Capture fault regressions passed (write failure, source isolation, format change, automatic shutdown, transcript recovery, cancelled startup).")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="meeting-capture-tests-") as directory:
    path = pathlib.Path(directory)
    source = path / "CaptureFailureTests.swift"
    source.write_text((ROOT / "MeetingCapture.swift").read_text() + harness)
    binary = path / "capture-tests"
    subprocess.run([
        "swiftc", "-DREGRESSION_TESTS", "-parse-as-library", "-swift-version", "5",
        "-target", "arm64-apple-macos13.0", "-framework", "AppKit", "-framework", "AVFoundation",
        "-framework", "CoreAudio", "-framework", "ApplicationServices", "-framework", "UniformTypeIdentifiers",
        str(ROOT / "TranscribeToText.swift"), str(ROOT / "BatchTranscription.swift"),
        str(ROOT / "ActivityCenter.swift"), str(ROOT / "LocalMeetingSummarizer.swift"),
        str(ROOT / "MeetingDetection.swift"), str(source), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
