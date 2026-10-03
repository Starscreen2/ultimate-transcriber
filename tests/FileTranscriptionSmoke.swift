import Foundation

@main
struct FileTranscriptionSmoke {
    static func main() throws {
        let files = FileManager.default
        let model = WhisperModel.choices.first { $0.id == "tiny" }!
        guard WhisperModel.isInstalled(at: model.localURL) else {
            throw AppError.message("Install the Tiny model before running the real file-transcription smoke test.")
        }
        let folder = files.temporaryDirectory.appendingPathComponent("transcriber-smoke-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("meeting.aiff")
        _ = try AppDelegate.run("/usr/bin/say", ["-o", audio.path,
            "This is a test meeting. Maya will send the project report on Friday. The team approved a budget of twelve hundred dollars."])
        var liveCount = 0
        let result = try AppDelegate.transcribe(file: audio, model: model, language: "en", detectSpeakers: true,
            control: OperationControl(), progress: { print($0) }, liveTranscript: { liveCount = $0.count })
        guard !result.segments.isEmpty, liveCount > 0,
              result.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }),
              result.speakerWarning == nil, !result.speakerIDs.isEmpty else {
            throw AppError.message("The real transcription/diarization pipeline did not finish correctly: \(result.speakerWarning ?? "missing transcript or speakers")")
        }
        let plain = try String(contentsOf: result.base.appendingPathExtension("txt"), encoding: .utf8)
        let srt = try String(contentsOf: result.base.appendingPathExtension("srt"), encoding: .utf8)
        let vtt = try String(contentsOf: result.base.appendingPathExtension("vtt"), encoding: .utf8)
        guard plain.lowercased().contains("meeting"), srt.contains("-->"), vtt.hasPrefix("WEBVTT\n\n"),
              AppDelegate.parseSRT(srt).count == result.segments.count else {
            throw AppError.message("The real pipeline's saved exports were invalid.")
        }
        let control = OperationControl()
        var cancelledDuringTranscript = false
        do {
            _ = try AppDelegate.transcribe(file: audio, model: model, language: "en", detectSpeakers: false,
                control: control, progress: { _ in }, liveTranscript: { _ in
                    cancelledDuringTranscript = true
                    control.cancel()
                })
            throw AppError.message("A cancelled real transcription unexpectedly succeeded.")
        } catch AppError.cancelled {
            guard cancelledDuringTranscript,
                  try String(contentsOf: result.base.appendingPathExtension("txt"), encoding: .utf8) == plain,
                  try String(contentsOf: result.base.appendingPathExtension("srt"), encoding: .utf8) == srt,
                  try String(contentsOf: result.base.appendingPathExtension("vtt"), encoding: .utf8) == vtt else {
                throw AppError.message("Cancellation changed the previous exports.")
            }
        }
        print("Passed real file transcription, live preview, diarization, three exports, and cancellation preservation")
    }
}
