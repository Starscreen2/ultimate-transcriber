import Foundation

// Run from a small app bundle whose Resources link to the built app. This loads
// the real meeting worker but denies the final gate, so no audio is captured.
@main
struct MeetingCaptureStartupSmoke {
    static func main() throws {
        guard #available(macOS 14.2, *), WhisperModel.isInstalled(at: MeetingCaptureController.turboModelURL) else {
            throw AppError.message("The startup smoke test needs macOS 14.2+ and the meeting model installed.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-startup-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingCaptureController()
        let completion = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var didGate = false
        var becameActive = false
        var failure: String?
        controller.onStateChange = { active in
            lock.lock(); becameActive = becameActive || active; lock.unlock()
        }
        controller.onFailure = { message, _ in
            lock.lock(); failure = message; lock.unlock()
            completion.signal()
        }
        controller.start(meetingsRoot: root, includeMicrophone: false, includeSystemAudio: true,
                         shouldBeginCapture: {
                             lock.withLock { didGate = true }
                             return false
                         })
        // Foundation Process exit notifications and Swift continuations may need
        // the main run loop even though no application window is involved.
        let deadline = Date().addingTimeInterval(150)
        var completed = false
        while Date() < deadline {
            if completion.wait(timeout: .now()) == .success { completed = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard completed else {
            controller.stop()
            throw AppError.message("Startup cancellation did not finish within its timeout.")
        }
        lock.lock()
        let valid = didGate && !becameActive && failure?.contains("Automatic recording canceled") == true
        lock.unlock()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        let capturedFiles = enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard valid, !controller.inProgress, capturedFiles.isEmpty else {
            throw AppError.message("A rejected capture gate activated or saved audio: \(failure ?? "no failure callback")")
        }
        print("Passed real meeting-worker startup: rejected final gate, no recording, no audio files, clean shutdown.")
    }
}
