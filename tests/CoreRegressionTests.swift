import Foundation
import AVFoundation

@main
struct CoreRegressionTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        checks += 1
        if (try? condition()) != true { fatalError(message) }
    }

    static func expectFailure(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError(message) } catch { checks += 1 }
    }

    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("transcriber-regressions-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        expect(AppDelegate.parseTimestamp(" 01:02:03,456 ") == 3723.456, "valid timestamp")
        for timestamp in ["00::00:01", "bad:00:00:01", "00:00:nan", "00:60:00", "00:00:60", "-1:00:00", "00:1e1:00"] {
            expect(AppDelegate.parseTimestamp(timestamp) == nil, "invalid timestamp accepted: \(timestamp)")
        }
        expect(AppDelegate.timeString(.nan, separator: ".") == "00:00:00.000", "NaN timestamp crashed")
        expect(AppDelegate.timeString(.infinity, separator: ".") == "00:00:00.000", "infinite timestamp crashed")
        expect(AppDelegate.timeString(59.9996, separator: ",") == "00:01:00,000", "timestamp carry")
        let cues = "1\r\n00:00:00,000 --> 00:00:01,000\r\n会议 café\r\n \t\r\n2\r\n00:00:01,000-->00:00:02,000\r\nsecond line\r\ncontinued\r\n\r\n3\r\n00:00:04,000 --> 00:00:03,000\r\nreversed"
        let segments = AppDelegate.parseSRT(cues)
        expect(segments.count == 2 && segments[0].text == "会议 café", "SRT cue boundaries")
        expect(segments[1].text == "second line continued", "multiline cue")
        expect(AppDelegate.parseDiarization("1.0 -- 0.5 speaker_0").isEmpty, "reversed diarization range")
        let echoed = [TranscriptSegment(start: 1, end: 2, text: "hello", speakerID: nil),
                      TranscriptSegment(start: 1.1, end: 2.1, text: "hello", speakerID: nil),
                      TranscriptSegment(start: 2, end: 3, text: "hello", speakerID: nil)]
        expect(MeetingCaptureController.uniqueMeetingSegments(echoed).count == 2, "meeting duplicate echoes reappeared")

        let base = root.appendingPathComponent("transcript")
        for ext in ["txt", "srt"] { try "previous \(ext)".write(to: base.appendingPathExtension(ext), atomically: true, encoding: .utf8) }
        try files.createDirectory(at: base.appendingPathExtension("vtt"), withIntermediateDirectories: false)
        expectFailure("partial exports should fail") { try AppDelegate.writeExports(base: base, segments: segments, names: [:]) }
        expect(try String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8) == "previous txt", "TXT was not rolled back")
        expect(try String(contentsOf: base.appendingPathExtension("srt"), encoding: .utf8) == "previous srt", "SRT was not rolled back")
        try files.removeItem(at: base.appendingPathExtension("vtt"))
        let cancelled = OperationControl()
        cancelled.cancel()
        expectFailure("cancelled export should fail") { try AppDelegate.writeExports(base: base, segments: segments, names: [:], control: cancelled) }
        expect(try String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8) == "previous txt", "cancel overwrote TXT")
        let marked = [TranscriptSegment(start: 0, end: 1, text: "a < b & c > d", speakerID: 0)]
        try AppDelegate.writeExports(base: base, segments: marked, names: [0: "<Ann>"])
        let vtt = try String(contentsOf: base.appendingPathExtension("vtt"), encoding: .utf8)
        expect(vtt.contains("&lt;Ann&gt;: a &lt; b &amp; c &gt; d"), "WebVTT literal markup")

        let python = ProcessInfo.processInfo.environment["TEST_PYTHON"] ?? "/opt/homebrew/bin/python3"
        var live: [TranscriptSegment] = []
        let text = "会议 café 🎙️"
        let unicodeScript = "import sys,time\nb='[00:00:00.000 --> 00:00:01.000] \(text)\\n'.encode()\ni=b.index('会'.encode())+1\nsys.stdout.buffer.write(b[:i]);sys.stdout.buffer.flush();time.sleep(.4);sys.stdout.buffer.write(b[i:]);sys.stdout.buffer.flush()"
        let output = try AppDelegate.run(python, ["-c", unicodeScript], onTranscriptSegment: { live.append($0) })
        expect(output.contains(text) && live.count == 1 && live[0].text == text, "split UTF8 corrupted transcription")
        var percentages: [String] = []
        _ = try AppDelegate.run(python, ["-c", "print('progress nan');print('progress 120%')"], progress: { percentages.append($0) })
        expect(percentages == ["100%"], "invalid numeric progress")
        let control = OperationControl()
        let start = Date()
        expectFailure("hung process should cancel") {
            _ = try AppDelegate.run(python, ["-c", "import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nprint('progress 1%',flush=True)\nwhile True: time.sleep(1)"], control: control, progress: { _ in control.cancel() })
        }
        expect(Date().timeIntervalSince(start) < 4, "cancellation did not stop an unresponsive process")

        let portURL = root.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: python)
        server.arguments = ["tests/model_download_fixture.py", portURL.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        for _ in 0..<200 { if files.fileExists(atPath: portURL.path) { break }; Thread.sleep(forTimeInterval: 0.01) }
        let port = try String(contentsOf: portURL, encoding: .utf8)
        func source(_ endpoint: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(endpoint)")! }
        let model = root.appendingPathComponent("model.bin")
        try AppDelegate.download(source("model"), to: model, control: OperationControl()) { _ in }
        expect(WhisperModel.isInstalled(at: model), "valid model not installed")
        try "broken cache".write(to: model, atomically: true, encoding: .utf8)
        try AppDelegate.download(source("model"), to: model, control: OperationControl()) { _ in }
        expect(WhisperModel.isInstalled(at: model), "corrupt cached model not replaced")
        for endpoint in ["empty", "html", "partial"] {
            let destination = root.appendingPathComponent(endpoint + ".bin")
            expectFailure("bad download accepted: \(endpoint)") {
                try AppDelegate.download(source(endpoint), to: destination, control: OperationControl()) { _ in }
            }
            expect(!files.fileExists(atPath: destination.path), "invalid model persisted")
        }
        let slow = root.appendingPathComponent("slow.bin")
        let downloadControl = OperationControl()
        expectFailure("download cancellation") {
            try AppDelegate.download(source("slow"), to: slow, control: downloadControl) { _ in downloadControl.cancel() }
        }
        expect(!files.fileExists(atPath: slow.path), "incomplete download persisted")
        expect(try files.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".download") && !$0.hasPrefix(".exports-") }, "staging files leaked")

        try testTranscriptRecovery(root: root)
        try testAudioOffsets(root: root)
        print("Passed \(checks) core regression checks")
    }

    static func testTranscriptRecovery(root: URL) throws {
        let folder = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let segments = [TranscriptSegment(start: 0.5, end: 1.5, text: "Captured text 会议", speakerID: nil)]
        let broken = folder.appendingPathComponent("broken.caf")
        try "invalid audio".write(to: broken, atomically: true, encoding: .utf8)
        for recordings: [(url: URL, offset: Double)] in [[], [(broken, 0)]] {
            expectFailure("audio failure should propagate") {
                _ = try MeetingCaptureController.saveTranscriptAndMixRecordings(in: folder, segments: segments, recordings: recordings)
            }
            for ext in ["txt", "srt", "vtt"] {
                let contents = try String(contentsOf: folder.appendingPathComponent("transcript." + ext), encoding: .utf8)
                expect(contents.contains(segments[0].text), "audio finalization lost the captured \(ext) transcript")
            }
            let srt = try String(contentsOf: folder.appendingPathComponent("transcript.srt"), encoding: .utf8)
            let recovered = AppDelegate.parseSRT(srt)
            expect(recovered.count == 1 && recovered[0].start == 0.5 && recovered[0].end == 1.5 && recovered[0].text == segments[0].text, "recovered transcript timestamps changed")
        }
        expect(FileManager.default.fileExists(atPath: broken.path), "failed audio conversion removed its recovery source")
    }

    static func testAudioOffsets(root: URL) throws {
        let source = root.appendingPathComponent("offset-source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16_000) * 0.3) }
        do {
            let audioFile = try AVAudioFile(forWriting: source, settings: format.settings)
            try audioFile.write(from: buffer)
        }
        let mix = try MeetingCaptureController.mixRecordings(in: root, recordings: [(source, 0.5)])
        let decoded = root.appendingPathComponent("mixed.wav")
        _ = try AppDelegate.run("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-y", "-i", mix.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_f32le", decoded.path])
        let file = try AVAudioFile(forReading: decoded)
        let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: samples)
        expect(samples.frameLength > 23_000, "audio offset missing from mixed duration")
        func rms(from: Int, through: Int) -> Double {
            let channel = samples.floatChannelData![0]
            return sqrt((from..<through).reduce(0.0) { $0 + pow(Double(channel[$1]), 2) } / Double(through - from))
        }
        expect(rms(from: 1000, through: 5000) < 0.003, "leading silence lost")
        expect(rms(from: 10_000, through: 14_000) > 0.15, "delayed audio missing")
    }
}
