import AVFoundation
import AppKit
import CoreAudio
import Darwin

final class InferenceJobQueue {
    static let shared = InferenceJobQueue()
    enum Completion { case completed, paused, cancelled, failed(String) }
    typealias Job = (@escaping (Completion) -> Void) -> Void
    private struct QueuedJob {
        let id: UUID
        let title: String
        let job: Job
        let preempt: (() -> Void)?
    }
    private let lock = NSLock()
    private var jobs: [QueuedJob] = []
    private var activeJob: QueuedJob?
    private var priorityLeases: Set<UUID> = []
    private var schedulingSuspendedForTermination = false
    var onIdle: (() -> Void)?
    var onQuiescentForTermination: (() -> Void)?

    private init() {}

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeJob != nil || !jobs.isEmpty || !priorityLeases.isEmpty
    }

    var canTerminateWithQueuedWork: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeJob == nil && priorityLeases.isEmpty &&
            (schedulingSuspendedForTermination || jobs.isEmpty)
    }

    func pausePendingWorkForTermination() {
        lock.lock()
        schedulingSuspendedForTermination = true
        let preempt = activeJob?.preempt
        let notify = activeJob == nil && priorityLeases.isEmpty ? onQuiescentForTermination : nil
        lock.unlock()
        preempt?()
        if let notify { DispatchQueue.main.async(execute: notify) }
    }

    @discardableResult
    func acquirePriorityLease() -> UUID {
        let lease = UUID()
        lock.lock()
        priorityLeases.insert(lease)
        let preempt = activeJob?.preempt
        lock.unlock()
        preempt?()
        return lease
    }

    func releasePriorityLease(_ lease: UUID) {
        lock.lock()
        priorityLeases.remove(lease)
        lock.unlock()
        startNextIfPossible()
    }

    func enqueue(id: UUID = UUID(), title: String, preempt: (() -> Void)? = nil, _ job: @escaping Job) {
        lock.lock()
        jobs.append(QueuedJob(id: id, title: title, job: job, preempt: preempt))
        lock.unlock()
        ActivityCenter.shared.update(id, state: .queued, detail: "Waiting for Whisper")
        startNextIfPossible()
    }

    func enqueue(_ job: @escaping (@escaping () -> Void) -> Void) {
        let id = UUID()
        enqueue(id: id, title: "Whisper transcription") { finish in
            job { finish(.completed) }
        }
    }

    func cancel(_ id: UUID) {
        lock.lock()
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs.remove(at: index)
            lock.unlock()
            ActivityCenter.shared.update(id, state: .cancelled, detail: "Canceled")
            return
        }
        let active = activeJob?.id == id ? activeJob : nil
        lock.unlock()
        active?.preempt?()
    }

    private func startNextIfPossible() {
        lock.lock()
        if schedulingSuspendedForTermination {
            let notify = activeJob == nil && priorityLeases.isEmpty ? onQuiescentForTermination : nil
            lock.unlock()
            if let notify { DispatchQueue.main.async(execute: notify) }
            return
        }
        guard activeJob == nil, priorityLeases.isEmpty else { lock.unlock(); return }
        guard !jobs.isEmpty else {
            let idle = onIdle
            lock.unlock()
            DispatchQueue.main.async { idle?() }
            return
        }
        let task = jobs.removeFirst()
        activeJob = task
        lock.unlock()
        ActivityCenter.shared.update(task.id, state: .running, detail: "Transcribing")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            task.job { [weak self] completion in self?.finish(task, completion: completion) }
        }
    }

    private func finish(_ task: QueuedJob, completion: Completion) {
        lock.lock()
        guard activeJob?.id == task.id else { lock.unlock(); return }
        activeJob = nil
        if case .paused = completion { jobs.insert(task, at: 0) }
        let notify = schedulingSuspendedForTermination && priorityLeases.isEmpty
            ? onQuiescentForTermination : nil
        lock.unlock()
        switch completion {
        case .completed: ActivityCenter.shared.update(task.id, state: .completed, detail: "Finished")
        case .paused: ActivityCenter.shared.update(task.id, state: .paused, detail: "Paused for the active recording")
        case .cancelled: ActivityCenter.shared.update(task.id, state: .cancelled, detail: "Canceled")
        case .failed(let message): ActivityCenter.shared.update(task.id, state: .failed, detail: message)
        }
        if let notify { DispatchQueue.main.async(execute: notify) }
        else { startNextIfPossible() }
    }
}

struct MeetingSessionResult {
    let sessionID: UUID
    let folder: URL
    let audioFile: URL
    let transcriptBase: URL
    let segments: [TranscriptSegment]
    let speakerIDs: [Int]
    let speakerWarning: String?
}

enum MeetingAudioValidationError: LocalizedError {
    case noUsableSignal

    var errorDescription: String? {
        switch self {
        case .noUsableSignal:
            return "No usable audio signal was captured. The transcript was not saved, and the original audio tracks were kept in the meeting folder. Check the selected microphone and system-audio access before recording again."
        }
    }
}

private enum MeetingAudioSource: String, Hashable {
    case microphone
    case system
}

@available(macOS 14.2, *)
private final class CoreAudioSystemCapture {
    private var tapID: AudioObjectID?
    private var aggregateDeviceID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "local.transcribetotext.system-audio")

    func start(onBuffer: @escaping (AVAudioPCMBuffer, Double) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Transcribe to Text Meeting Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &createdTap), action: "create the system-audio tap")
        tapID = createdTap

        do {
            let tapUID = try readTapUID(createdTap)
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Transcribe to Text Meeting Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            var createdAggregate = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregate),
                           action: "create the system-audio input")
            aggregateDeviceID = createdAggregate
            let format = try readTapFormat(createdTap)

            var createdIOProc: AudioDeviceIOProcID?
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&createdIOProc, createdAggregate, ioQueue) {
                _, inputData, inputTime, _, _ in
                guard let buffer = Self.copyAudioBuffer(inputData, format: format) else { return }
                let time = inputTime.pointee
                let capturedAt = time.mFlags.contains(.hostTimeValid)
                    ? AVAudioTime.seconds(forHostTime: time.mHostTime)
                    : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / format.sampleRate
                onBuffer(buffer, capturedAt)
            }, action: "prepare the system-audio stream")
            ioProcID = createdIOProc
            try Self.check(AudioDeviceStart(createdAggregate, createdIOProc), action: "start system-audio capture")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let aggregateDeviceID {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if let tapID { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = nil
        aggregateDeviceID = nil
        ioProcID = nil
    }

    private func readTapUID(_ objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        try Self.check(status, action: "read the system-audio tap identifier")
        return uid as String
    }

    private func readTapFormat(_ objectID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        try Self.check(status, action: "read the system-audio format")
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw AppError.message("macOS returned an unsupported system-audio format.")
        }
        return format
    }

    private static func copyAudioBuffer(_ source: UnsafePointer<AudioBufferList>,
                                        format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.sampleRate > 0, format.streamDescription.pointee.mBytesPerFrame > 0 else { return nil }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        guard let first = sourceBuffers.first,
              format.streamDescription.pointee.mBytesPerFrame > 0 else { return nil }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let frameCount = first.mDataByteSize / bytesPerFrame
        guard frameCount > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        copy.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<sourceBuffers.count {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceBuffer.mDataByteSize <= destinationBuffers[index].mDataByteSize else { return nil }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return copy
    }

    private static func check(_ status: OSStatus, action: String) throws {
        guard status == noErr else {
            throw AppError.message("Could not \(action) (Core Audio error \(status)).")
        }
    }
}

private final class MeetingAudioSourceState {
    let sessionID: UUID
    let source: MeetingAudioSource
    let recordingURL: URL
    var file: AVAudioFile?
    var converter: AVAudioConverter?
    var inputFormat: AVAudioFormat?
    var pendingSamples: [Float] = []
    var sessionOffset: Double?
    // Accessed only on the controller's serial capture queue.
    var acceptsAudio = true
    let worker: LiveWhisperWorker?

    init(sessionID: UUID, source: MeetingAudioSource, recordingURL: URL, worker: LiveWhisperWorker?) {
        self.sessionID = sessionID
        self.source = source
        self.recordingURL = recordingURL
        self.worker = worker
    }
}

private final class LiveWhisperWorker: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let inputQueue = DispatchQueue(label: "local.transcribetotext.whisper-input")
    private let stateLock = NSLock()
    private let outputClosed = DispatchGroup()
    private let processExited = DispatchGroup()
    private let outputQueue = DispatchQueue(label: "local.transcribetotext.whisper-output")
    private var outputBuffer = Data()
    private var segmentBuffer: [TranscriptSegment] = []
    private var ready = DispatchSemaphore(value: 0)
    private var didBecomeReady = false
    private var didCloseOutput = false
    private var didExitProcess = false
    private var didRequestFinish = false
    private var didFinishNormally = false
    private var failureMessage: String?
    private var pendingInputBytes = 0
    private var inputFailed = false
    // Bound queued PCM when inference stalls. Audio still goes to the source file;
    // after overflow, never resume this worker with gaps that shift timestamps.
    static let maxPendingInputBytes = 8 * 1024 * 1024
    private let onWarning: ((String) -> Void)?
    private let onSegment: (TranscriptSegment) -> Void

    init(onWarning: ((String) -> Void)? = nil, onSegment: @escaping (TranscriptSegment) -> Void) {
        self.onWarning = onWarning
        self.onSegment = onSegment
        outputClosed.enter()
        processExited.enter()
    }

    func start(executable: URL, model: URL, control: OperationControl? = nil) throws {
        process.executableURL = executable
        process.arguments = ["--model", model.path, "--language", "auto", "--threads", "4", "--chunk-seconds", "4"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in self?.signalProcessExited() }
        // A closed child stdin must throw EPIPE instead of terminating the app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.outputQueue.async {
                self.consume(data, isFinal: data.isEmpty)
                if data.isEmpty { self.signalOutputClosed() }
            }
        }
        defer { control?.detach(process) }
        do {
            try control?.check()
            try process.run()
            control?.attach(process)
        } catch {
            signalProcessExited()
            stopImmediately()
            throw error
        }
        // The parent must not retain either child-side pipe end. In particular,
        // retaining stdin's read end makes a failed worker's writes block forever.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        guard ready.wait(timeout: .now() + 120) == .success else {
            stopImmediately()
            throw AppError.message("The live transcription model did not finish loading.")
        }
        do { try control?.check() }
        catch { stopImmediately(); throw error }
        stateLock.lock()
        let becameReady = didBecomeReady
        stateLock.unlock()
        guard becameReady, process.isRunning else {
            stopImmediately()
            throw AppError.message("The live transcription engine exited before it was ready.")
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let byteCount = samples.count * MemoryLayout<Float>.stride
        stateLock.lock()
        guard !didRequestFinish, !didExitProcess, !inputFailed else { stateLock.unlock(); return }
        guard byteCount <= Self.maxPendingInputBytes - pendingInputBytes else {
            inputFailed = true
            stateLock.unlock()
            recordFailure("Live transcription fell behind. Further audio is being saved without live text; transcribe the saved recording afterward.")
            return
        }
        pendingInputBytes += byteCount
        stateLock.unlock()
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        inputQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.pendingInputBytes -= byteCount
                self.stateLock.unlock()
            }
            guard self.process.isRunning else {
                self.recordFailure("The live transcription engine stopped before the meeting ended.")
                return
            }
            do { try self.inputPipe.fileHandleForWriting.write(contentsOf: data) }
            catch { self.recordFailure("Live transcription input failed: \(error.localizedDescription)") }
        }
    }

    var failureWarning: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return failureMessage
    }

    func finish(timeout: TimeInterval = 300) async -> [TranscriptSegment] {
        markFinishing()
        return await withCheckedContinuation { continuation in
            inputQueue.async { [weak self] in
                try? self?.inputPipe.fileHandleForWriting.close()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                // This wait is independent of the input queue: a hung worker can
                // block a pipe write and otherwise prevent stdin from closing.
                if self.processExited.wait(timeout: .now() + timeout) != .success {
                    self.recordFailure("The live transcription engine did not finish in time. The captured audio was preserved.")
                    self.stopImmediately()
                }
                if self.outputClosed.wait(timeout: .now() + 2) != .success {
                    self.recordFailure("The live transcription output did not close after the engine exited.")
                    self.closeOutput()
                }
                self.stateLock.lock()
                if !self.process.isRunning, self.process.terminationStatus != 0, self.failureMessage == nil {
                    self.failureMessage = "The live transcription engine exited with code \(self.process.terminationStatus)."
                } else if !self.didFinishNormally, self.failureMessage == nil {
                    self.failureMessage = "The live transcription engine ended without a completion signal."
                }
                let segments = self.segmentBuffer
                self.stateLock.unlock()
                continuation.resume(returning: segments)
            }
        }
    }

    private func markFinishing() {
        stateLock.lock()
        didRequestFinish = true
        stateLock.unlock()
    }

    private func stopImmediately() {
        if process.isRunning {
            process.terminate()
            if processExited.wait(timeout: .now() + 2) != .success {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = processExited.wait(timeout: .now() + 2)
            }
        }
        try? inputPipe.fileHandleForWriting.close()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        closeOutput()
    }

    private func closeOutput() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        outputQueue.sync {
            consume(Data(), isFinal: true)
            signalOutputClosed()
        }
        try? outputPipe.fileHandleForReading.close()
    }

    private func signalProcessExited() {
        stateLock.lock()
        let shouldSignal = !didExitProcess
        let shouldSignalReady = !didBecomeReady
        didExitProcess = true
        stateLock.unlock()
        if shouldSignal { processExited.leave() }
        if shouldSignalReady { ready.signal() }
    }

    private func consume(_ data: Data, isFinal: Bool = false) {
        stateLock.lock()
        outputBuffer.append(data)
        var lines: [Data] = []
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            lines.append(outputBuffer.subdata(in: outputBuffer.startIndex..<newline))
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
        }
        if isFinal, !outputBuffer.isEmpty {
            lines.append(outputBuffer)
            outputBuffer.removeAll(keepingCapacity: false)
        }
        stateLock.unlock()

        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "ready" {
                stateLock.lock()
                let shouldSignal = !didBecomeReady
                didBecomeReady = true
                stateLock.unlock()
                if shouldSignal { ready.signal() }
            } else if type == "segment",
                      let start = object["start"] as? Double,
                      let end = object["end"] as? Double,
                      let value = object["text"] as? String,
                      start.isFinite, end.isFinite, start >= 0, end >= start {
                let segment = TranscriptSegment(start: start, end: end, text: value.trimmingCharacters(in: .whitespacesAndNewlines), speakerID: nil)
                guard !segment.text.isEmpty else { continue }
                stateLock.lock()
                segmentBuffer.append(segment)
                stateLock.unlock()
                onSegment(segment)
            } else if type == "finished" {
                stateLock.lock()
                didFinishNormally = true
                stateLock.unlock()
            }
        }
    }

    private func recordFailure(_ message: String) {
        stateLock.lock()
        let shouldWarn = failureMessage == nil
        if shouldWarn { failureMessage = message }
        inputFailed = true
        stateLock.unlock()
        if shouldWarn { onWarning?(message) }
    }

    private func signalOutputClosed() {
        stateLock.lock()
        let shouldSignalOutput = !didCloseOutput
        let shouldSignalReady = !didBecomeReady
        didCloseOutput = true
        stateLock.unlock()
        if shouldSignalOutput { outputClosed.leave() }
        if shouldSignalReady { ready.signal() }
    }
}

final class MeetingCaptureController: NSObject {
    var onStatus: ((UUID, String) -> Void)?
    var onStateChange: ((UUID, Bool) -> Void)?
    var onLiveSegments: ((UUID, [TranscriptSegment]) -> Void)?
    var onCaptureStopped: ((UUID) -> Void)?
    var onFinished: ((MeetingSessionResult) -> Void)?
    var onFailure: ((UUID, String, URL?) -> Void)?

    private let captureQueue = DispatchQueue(label: "local.transcribetotext.meeting-audio")
    private let stateLock = NSLock()
    private var sourceStates: [MeetingAudioSource: MeetingAudioSourceState] = [:]
    private var audioEngine: AVAudioEngine?
    private var systemCapture: AnyObject?
    private var sessionFolder: URL?
    private var sessionID = UUID()
    private var sessionStartedAt = 0.0
    private var sessionSegments: [TranscriptSegment] = []
    private var isActive = false
    private var isStarting = false
    private var isStopping = false
    private var observedCaptureError: String?
    private var preparationControl: OperationControl?
    private var preparingWorkers: [LiveWhisperWorker] = []
    private var stopRequested = false
    private var liveTranscriptionEnabled = false
    private var priorityLeaseID: UUID?

    var active: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isActive
    }

    var inProgress: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isActive || isStarting || isStopping
    }

    private func updateState(active: Bool? = nil, starting: Bool? = nil, stopping: Bool? = nil) {
        stateLock.lock()
        if let active { isActive = active }
        if let starting {
            isStarting = starting
            if !starting { preparationControl = nil }
        }
        if let stopping { isStopping = stopping }
        stateLock.unlock()
    }

    private func allSourceStates() -> [MeetingAudioSource: MeetingAudioSourceState] {
        stateLock.lock(); defer { stateLock.unlock() }
        return sourceStates
    }

    private func installSourceState(_ state: MeetingAudioSourceState) {
        stateLock.lock()
        sourceStates[state.source] = state
        if let worker = state.worker { preparingWorkers.removeAll { $0 === worker } }
        stateLock.unlock()
    }

    private func removePreparingWorker(_ worker: LiveWhisperWorker) {
        stateLock.lock()
        preparingWorkers.removeAll { $0 === worker }
        stateLock.unlock()
    }

    private func takePreparingWorkers() -> [LiveWhisperWorker] {
        stateLock.lock(); defer { stateLock.unlock() }
        let workers = preparingWorkers
        preparingWorkers.removeAll()
        return workers
    }

    private func completeStartup() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopRequested else { throw AppError.cancelled }
        isActive = true
        isStarting = false
        isStopping = false
        preparationControl = nil
    }

    private func removeSourceState(_ source: MeetingAudioSource) -> MeetingAudioSourceState? {
        stateLock.lock(); defer { stateLock.unlock() }
        return sourceStates.removeValue(forKey: source)
    }

    private func clearSourceStates() {
        stateLock.lock()
        sourceStates.removeAll()
        stateLock.unlock()
    }

    private func captureWarning() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return observedCaptureError
    }

    private func resetSessionTimeline() {
        stateLock.lock()
        sessionSegments = []
        sessionStartedAt = 0
        observedCaptureError = nil
        stateLock.unlock()
    }

    private func offset(for state: MeetingAudioSourceState) -> Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.sessionOffset ?? 0
    }

    static var turboModelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscribeToText/models", isDirectory: true)
            .appendingPathComponent("ggml-large-v3-turbo.bin")
    }

    func start(sessionID: UUID, priorityLeaseID: UUID, meetingsRoot: URL, includeMicrophone: Bool, includeSystemAudio: Bool,
               shouldBeginCapture: (() async -> Bool)? = nil) {
        stateLock.lock()
        guard !isActive, !isStarting, !isStopping else { stateLock.unlock(); return }
        isStarting = true
        stopRequested = false
        sessionFolder = nil
        self.sessionID = sessionID
        self.priorityLeaseID = priorityLeaseID
        liveTranscriptionEnabled = true
        let control = OperationControl()
        preparationControl = control
        stateLock.unlock()
        Task {
            do {
                try await beginSession(meetingsRoot: meetingsRoot,
                                       includeMicrophone: includeMicrophone,
                                       includeSystemAudio: includeSystemAudio, control: control,
                                       shouldBeginCapture: shouldBeginCapture)
            } catch {
                await cleanupAfterFailedStart()
                let preservedFolder = sessionFolder.flatMap { folder -> URL? in
                    guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !items.isEmpty else { return nil }
                    return folder
                }
                updateState(active: false, starting: false, stopping: false)
                InferenceJobQueue.shared.releasePriorityLease(priorityLeaseID)
                onStateChange?(sessionID, false)
                let details = [error.localizedDescription, captureWarning()].compactMap { $0 }.joined(separator: " ")
                onFailure?(sessionID, details, preservedFolder)
            }
        }
    }

    func stop() {
        stateLock.lock()
        if isStarting {
            stopRequested = true
            let control = preparationControl
            stateLock.unlock()
            control?.cancel()
            return
        }
        guard isActive, !isStopping else { stateLock.unlock(); return }
        isStopping = true
        stateLock.unlock()
        Task { await finishSession() }
    }

    private func beginSession(meetingsRoot: URL, includeMicrophone: Bool, includeSystemAudio: Bool, control: OperationControl,
                              shouldBeginCapture: (() async -> Bool)?) async throws {
        let startedSessionID = sessionID
        try control.check()
        guard includeMicrophone || includeSystemAudio else {
            throw AppError.message("Turn on at least one meeting audio source in Settings.")
        }
        try FileManager.default.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let baseName = formatter.string(from: Date())
        var folder = meetingsRoot.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = meetingsRoot.appendingPathComponent("\(baseName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        resetSessionTimeline()

        onStatus?(startedSessionID, "Checking selected audio-source access…")
        let microphonePermission = includeMicrophone ? await Self.requestMicrophonePermission() : false
        try control.check()
        var microphoneError: String? = includeMicrophone && !microphonePermission
            ? "Microphone access is unavailable. Check System Settings → Privacy & Security → Microphone."
            : nil
        var systemAudioError: String? = nil
        if includeSystemAudio {
            if #available(macOS 14.2, *) {
                // The system-audio source is started after the model is ready so that no
                // microphone audio is collected while macOS presents the system-audio prompt.
            } else {
                systemAudioError = "System-audio capture requires macOS 14.2 or later."
            }
        }

        let canUseMicrophone = includeMicrophone && microphonePermission
        let canUseSystemAudio: Bool = {
            guard includeSystemAudio else { return false }
            if #available(macOS 14.2, *) { return true }
            return false
        }()
        guard canUseMicrophone || canUseSystemAudio else {
            let reasons = [microphoneError, systemAudioError].compactMap { $0 }.joined(separator: " ")
            throw AppError.message("No selected meeting audio source is available. \(reasons)")
        }

        onStatus?(startedSessionID, liveTranscriptionEnabled
            ? "Preparing the local live transcription model…"
            : "Recording now. Whisper is busy; this meeting will be transcribed when it is its turn…")
        let modelURL = Self.turboModelURL
        if liveTranscriptionEnabled && !WhisperModel.isInstalled(at: modelURL) {
            guard let model = WhisperModel.choices.first(where: { $0.id == "large-v3-turbo" }) else {
                throw AppError.message("The Large v3 Turbo meeting model is not configured.")
            }
            try await Self.downloadMeetingModel(from: model.url, to: modelURL, control: control) { [weak self] message in
                self?.onStatus?(startedSessionID, message)
            }
        }

        try control.check()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sessionFolder = folder
        ActivityCenter.shared.add(kind: .recording, title: folder.lastPathComponent,
                                  state: .recording, detail: "Recording meeting audio", folderURL: folder,
                                  id: startedSessionID)

        var microphoneWorker: LiveWhisperWorker?
        if canUseMicrophone && liveTranscriptionEnabled {
            do { microphoneWorker = try makeWorker(source: .microphone, model: modelURL, control: control) }
            catch { microphoneError = error.localizedDescription }
        }

        try control.check()
        var systemWorker: LiveWhisperWorker?
        if canUseSystemAudio && liveTranscriptionEnabled {
            do { systemWorker = try makeWorker(source: .system, model: modelURL, control: control) }
            catch { systemAudioError = error.localizedDescription }
        }

        try control.check()
        if let shouldBeginCapture, !(await shouldBeginCapture()) {
            throw AppError.message("Automatic recording canceled because the detected call is no longer confirmed. Start manually if you are still in the meeting.")
        }
        try control.check()
        // Start system audio first so a system-audio permission prompt never leaves the
        // microphone recording while setup is blocked.
        if canUseSystemAudio {
            if #available(macOS 14.2, *) {
                do { try startSystemAudio(worker: systemWorker, folder: folder) }
                catch {
                    systemAudioError = "System-audio capture could not start. Allow system-audio access in System Settings and try again. \(error.localizedDescription)"
                    if let state = removeSourceState(.system), let worker = state.worker { _ = await worker.finish() }
                    if let systemWorker { _ = await systemWorker.finish(); removePreparingWorker(systemWorker) }
                }
            }
        }

        try control.check()
        if canUseMicrophone {
            do { try startMicrophone(worker: microphoneWorker, folder: folder) }
            catch {
                microphoneError = error.localizedDescription
                if let state = removeSourceState(.microphone), let worker = state.worker { _ = await worker.finish() }
                if let microphoneWorker { _ = await microphoneWorker.finish(); removePreparingWorker(microphoneWorker) }
            }
        }

        let startedSources = allSourceStates()
        guard !startedSources.isEmpty else {
            let reasons = [microphoneError, systemAudioError].compactMap { $0 }.joined(separator: " ")
            throw AppError.message("No selected meeting audio source could start. \(reasons)")
        }

        // Stop requested during preparation must win over entering capture.
        try completeStartup()
        onStateChange?(sessionID, true)
        let available = startedSources.keys.map { $0 == .microphone ? "microphone" : "system audio" }.sorted().joined(separator: " and ")
        let missing = [microphoneError, systemAudioError].compactMap { $0 }
        if !liveTranscriptionEnabled {
            onStatus?(startedSessionID, "Recording. Transcript will start when Whisper is available…")
        } else if missing.isEmpty {
            onStatus?(startedSessionID, "")
        } else {
            onStatus?(startedSessionID, "Only \(available) is available. Another audio source is unavailable: \(missing.joined(separator: " "))")
        }
    }

    private static func requestMicrophonePermission(
        status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio),
        requestAccess: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
        }
    ) async -> Bool {
        // Always consult macOS, so revocation takes effect. Only an undecided
        // authorization can show a prompt; later meetings reuse the OS grant.
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                requestAccess { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    private func startMicrophone(worker: LiveWhisperWorker?, folder: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError.message("macOS did not provide an audio input format for the microphone.")
        }
        let state = MeetingAudioSourceState(sessionID: sessionID, source: .microphone,
                                            recordingURL: folder.appendingPathComponent("microphone.caf"),
                                            worker: worker)
        installSourceState(state)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            guard let copied = Self.copyAudioBuffer(buffer) else { return }
            let capturedAt = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime - Double(buffer.frameLength) / buffer.format.sampleRate
            self.captureQueue.async { self.consume(copied, for: state, capturedAt: capturedAt) }
        }
        do {
            try engine.start()
            audioEngine = engine
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    @available(macOS 14.2, *)
    private func startSystemAudio(worker: LiveWhisperWorker?, folder: URL) throws {
        let state = MeetingAudioSourceState(sessionID: sessionID, source: .system,
                                            recordingURL: folder.appendingPathComponent("meeting-audio.caf"),
                                            worker: worker)
        installSourceState(state)

        let capture = CoreAudioSystemCapture()
        try capture.start { [weak self] buffer, capturedAt in
            guard let self else { return }
            self.captureQueue.async { self.consume(buffer, for: state, capturedAt: capturedAt) }
        }
        systemCapture = capture
    }

    private func makeWorker(source: MeetingAudioSource, model: URL, control: OperationControl) throws -> LiveWhisperWorker {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("meeting-whisper"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppError.message("The live Whisper engine is missing. Rebuild the app with ./build-app.sh.")
        }
        let workerSessionID = sessionID
        let worker = LiveWhisperWorker(onWarning: { [weak self] message in self?.onStatus?(workerSessionID, message) }) { [weak self] segment in
            self?.receive(segment, source: source, sessionID: workerSessionID)
        }
        try worker.start(executable: executable, model: model, control: control)
        stateLock.lock()
        preparingWorkers.append(worker)
        stateLock.unlock()
        return worker
    }

    private static func copyAudioBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in 0..<sourceBuffers.count {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceBuffer.mDataByteSize <= destinationBuffers[index].mDataByteSize else { return nil }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return copy
    }

    private func consume(_ buffer: AVAudioPCMBuffer, for state: MeetingAudioSourceState, capturedAt now: Double) {
        guard state.acceptsAudio else { return }
        stateLock.lock()
        guard sourceStates[state.source] === state else { stateLock.unlock(); return }
        if sessionStartedAt == 0 { sessionStartedAt = now }
        if state.sessionOffset == nil { state.sessionOffset = max(0, now - sessionStartedAt) }
        stateLock.unlock()
        do {
            if state.file == nil {
                state.file = try AVAudioFile(forWriting: state.recordingURL, settings: buffer.format.settings,
                                             commonFormat: buffer.format.commonFormat,
                                             interleaved: buffer.format.isInterleaved)
                state.inputFormat = buffer.format
                if state.worker != nil {
                    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                     channels: 1, interleaved: false),
                          let converter = AVAudioConverter(from: buffer.format, to: target) else {
                        throw AppError.message("The meeting audio format could not be converted for live transcription.")
                    }
                    state.converter = converter
                }
            }
            if let format = state.inputFormat, !format.isEqual(buffer.format) {
                throw AppError.message("The audio device changed format during recording. Start a new recording to use the new device.")
            }
            try state.file?.write(from: buffer)
            guard let worker = state.worker, let converter = state.converter else { return }
            let target = converter.outputFormat
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let conversionStatus = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard conversionStatus != .error, let samples = converted.floatChannelData?.pointee else {
                throw conversionError ?? NSError(domain: "MeetingCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The audio converter stopped producing live transcription samples."])
            }
            let count = Int(converted.frameLength)
            if count > 0 { state.pendingSamples.append(contentsOf: UnsafeBufferPointer(start: samples, count: count)) }
            let packetSize = 16_000
            while state.pendingSamples.count >= packetSize {
                let packet = Array(state.pendingSamples.prefix(packetSize))
                state.pendingSamples.removeFirst(packetSize)
                worker.append(packet)
            }
        } catch {
            // Retrying a failed file/converter on every buffer silently loses audio
            // and floods the capture queue. Retire this source and tell the user.
            state.acceptsAudio = false
            state.file = nil
            let source = state.source == .microphone ? "Microphone" : "System audio"
            let message = "\(source) recording stopped: \(error.localizedDescription)"
            stateLock.lock()
            observedCaptureError = [observedCaptureError, message].compactMap { $0 }.joined(separator: " ")
            stateLock.unlock()
            onStatus?(state.sessionID, message)
            if allSourceStates().values.allSatisfy({ !$0.acceptsAudio }) { stop() }
        }
    }

    private func receive(_ segment: TranscriptSegment, source: MeetingAudioSource, sessionID: UUID) {
        stateLock.lock()
        guard let state = sourceStates[source], state.sessionID == sessionID,
              let offset = state.sessionOffset else { stateLock.unlock(); return }
        let adjusted = TranscriptSegment(start: segment.start + offset, end: segment.end + offset,
                                         text: segment.text, speakerID: nil)
        sessionSegments = Self.uniqueMeetingSegments(sessionSegments + [adjusted])
        let snapshot = sessionSegments
        stateLock.unlock()
        onLiveSegments?(sessionID, snapshot)
    }

    static func uniqueMeetingSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let ordered = segments.sorted { $0.start < $1.start }
        var lastAcceptedStart: [String: Double] = [:]
        return ordered.filter { segment in
            if let previous = lastAcceptedStart[segment.text], segment.start - previous < 0.25 { return false }
            lastAcceptedStart[segment.text] = segment.start
            return true
        }
    }

    private func finishSession() async {
        let stoppingSessionID = sessionID
        let finishingPriorityLeaseID = priorityLeaseID
        onStatus?(stoppingSessionID, "Finishing live transcription and saving the meeting…")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if #available(macOS 14.2, *) {
            (systemCapture as? CoreAudioSystemCapture)?.stop()
            systemCapture = nil
        }

        let states = allSourceStates()
        captureQueue.sync {
            for state in states.values {
                state.acceptsAudio = false
                if let worker = state.worker, !state.pendingSamples.isEmpty {
                    worker.append(state.pendingSamples)
                    state.pendingSamples.removeAll(keepingCapacity: false)
                }
                state.file = nil
            }
        }

        let folder = sessionFolder
        let finishedSessionID = sessionID

        let sessionWarning: String? = stateLock.withLock {
            let warning = observedCaptureError
            sourceStates.removeAll()
            sessionFolder = nil
            sessionSegments = []
            sessionStartedAt = 0
            observedCaptureError = nil
            isActive = false
            isStopping = false
            return warning
        }
        // Release audio capture as soon as its files are closed. A new meeting
        // can now start while this session finishes decoding its final chunks.
        onStateChange?(finishedSessionID, false)
        onCaptureStopped?(finishedSessionID)

        guard states.values.contains(where: { $0.worker != nil }) else {
            // This session has no live worker. Close and mix its audio, then
            // enqueue a normal local transcription (or transfer its queue lease).
            do {
                guard let folder else { throw AppError.message("The meeting folder is missing.") }
                let recordings = states.values.map { (url: $0.recordingURL, offset: self.offset(for: $0)) }
                let audio = try Self.mixRecordings(in: folder, recordings: recordings)
                let transcriptModel = WhisperModel.choices.first(where: { $0.id == "large-v3-turbo" })
                    ?? WhisperModel.choices[0]
                ActivityCenter.shared.add(kind: .transcription, title: folder.lastPathComponent,
                    state: .queued, detail: "Waiting for Whisper", sourceURL: audio, folderURL: folder,
                    modelID: transcriptModel.id, language: "auto", detectSpeakers: true,
                    outputBaseURL: folder.appendingPathComponent("transcript"), id: finishedSessionID)
                let work = PreemptibleWorkState()
                InferenceJobQueue.shared.enqueue(id: finishedSessionID, title: folder.lastPathComponent,
                                                 preempt: { work.preempt() }) { [weak self] finishJob in
                    guard let self else { finishJob(.failed("Meeting controller was closed")); return }
                    let control = work.beginAttempt()
                    do {
                        let result = try AppDelegate.transcribe(
                            file: audio, model: transcriptModel, language: "auto", detectSpeakers: true,
                            control: control, progress: { [weak self] message in
                                self?.onStatus?(finishedSessionID, message)
                            }, liveTranscript: { _ in }, outputBaseOverride: folder.appendingPathComponent("transcript"))
                        let warnings = [sessionWarning, result.speakerWarning].compactMap { $0 }.joined(separator: " ")
                        self.onFinished?(MeetingSessionResult(sessionID: finishedSessionID, folder: folder,
                            audioFile: audio, transcriptBase: result.base, segments: result.segments,
                            speakerIDs: result.speakerIDs, speakerWarning: warnings.isEmpty ? nil : warnings))
                    } catch {
                        if work.shouldRequeue {
                            work.prepareForRetryAfterPreemption()
                            ActivityCenter.shared.update(finishedSessionID, state: .paused,
                                detail: "Paused for the active recording; will restart from saved audio")
                            finishJob(.paused)
                            return
                        }
                        self.onFailure?(finishedSessionID,
                            "Meeting transcript failed. The recording remains saved: \(error.localizedDescription)", folder)
                        finishJob(.failed(error.localizedDescription))
                        return
                    }
                    finishJob(.completed)
                }
            if let finishingPriorityLeaseID { InferenceJobQueue.shared.releasePriorityLease(finishingPriorityLeaseID) }
            } catch {
                if let finishingPriorityLeaseID { InferenceJobQueue.shared.releasePriorityLease(finishingPriorityLeaseID) }
                onFailure?(finishedSessionID,
                    "Meeting audio could not be prepared for transcription: \(error.localizedDescription)", folder)
            }
            return
        }

        var finalSegments: [TranscriptSegment] = []
        for state in states.values {
            guard let worker = state.worker else { continue }
            let segments = await worker.finish()
            let offset = self.offset(for: state)
            finalSegments += segments.map {
                TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text, speakerID: nil)
            }
        }
        finalSegments = Self.uniqueMeetingSegments(finalSegments)

        do {
            guard let folder else { throw AppError.message("The meeting folder is missing.") }
            let recordings = states.values.map { (url: $0.recordingURL, offset: self.offset(for: $0)) }
            let saved = try Self.saveTranscriptAndMixRecordings(in: folder, segments: finalSegments, recordings: recordings)
            let audio = saved.audio
            let diarization = try await Self.detectSpeakers(in: audio)
            var labeled = finalSegments
            for index in labeled.indices {
                var overlaps: [Int: Double] = [:]
                for turn in diarization.turns {
                    let overlap = max(0, min(labeled[index].end, turn.end) - max(labeled[index].start, turn.start))
                    if let speaker = turn.speakerID, overlap > 0 { overlaps[speaker, default: 0] += overlap }
                }
                labeled[index].speakerID = overlaps.max(by: { $0.value < $1.value })?.key
            }
            let speakerIDs = Array(Set(labeled.compactMap(\.speakerID))).sorted()
            let base = saved.transcriptBase
            let names = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map { ($1, "Speaker \($0 + 1)") })
            try AppDelegate.writeExports(base: base, segments: labeled, names: names)
            let warnings = [diarization.warning, sessionWarning] + states.values.compactMap { $0.worker?.failureWarning }
            let warning = warnings.compactMap { $0 }.joined(separator: " ")
            onFinished?(MeetingSessionResult(sessionID: finishedSessionID, folder: folder, audioFile: audio, transcriptBase: base,
                                            segments: labeled, speakerIDs: speakerIDs,
                                            speakerWarning: warning.isEmpty ? nil : warning))
        } catch {
            let details = [sessionWarning, error.localizedDescription].compactMap { $0 }.joined(separator: " ")
            onFailure?(finishedSessionID, "Meeting final processing failed. Saved files remain in the meeting folder: \(details)", folder)
        }
        if let finishingPriorityLeaseID { InferenceJobQueue.shared.releasePriorityLease(finishingPriorityLeaseID) }
    }

    private func cleanupAfterFailedStart() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if #available(macOS 14.2, *) {
            (systemCapture as? CoreAudioSystemCapture)?.stop()
            systemCapture = nil
        }
        let states = allSourceStates()
        captureQueue.sync {
            for state in states.values {
                state.acceptsAudio = false
                if let worker = state.worker, !state.pendingSamples.isEmpty {
                    worker.append(state.pendingSamples)
                    state.pendingSamples.removeAll(keepingCapacity: false)
                }
                state.file = nil
            }
        }
        let unattachedWorkers = takePreparingWorkers()
        var recovered: [TranscriptSegment] = []
        for state in states.values {
            guard let worker = state.worker else { continue }
            let offset = self.offset(for: state)
            recovered += await worker.finish().map {
                TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text, speakerID: nil)
            }
        }
        for worker in unattachedWorkers { _ = await worker.finish() }
        if let sessionFolder, !recovered.isEmpty {
            do {
                try AppDelegate.writeExports(base: sessionFolder.appendingPathComponent("transcript"),
                                             segments: Self.uniqueMeetingSegments(recovered), names: [:])
            } catch {
                stateLock.withLock { observedCaptureError = [observedCaptureError, error.localizedDescription].compactMap { $0 }.joined(separator: " ") }
            }
        }
        clearSourceStates()
        if let sessionFolder,
           let items = try? FileManager.default.contentsOfDirectory(atPath: sessionFolder.path), items.isEmpty {
            try? FileManager.default.removeItem(at: sessionFolder)
            self.sessionFolder = nil
        }
    }

    // Preserve transcript text if an unrelated mix error occurs, but never
    // save live-model guesses when the captured audio is effectively silent.
    static func saveTranscriptAndMixRecordings(in folder: URL, segments: [TranscriptSegment],
                                               recordings: [(url: URL, offset: Double)]) throws -> (audio: URL, transcriptBase: URL) {
        let base = folder.appendingPathComponent("transcript")
        let audio: URL
        do {
            audio = try mixRecordings(in: folder, recordings: recordings)
        } catch {
            if !(error is MeetingAudioValidationError) {
                try? AppDelegate.writeExports(base: base, segments: segments, names: [:])
            }
            throw error
        }
        try AppDelegate.writeExports(base: base, segments: segments, names: [:])
        return (audio, base)
    }

    static func mixRecordings(in folder: URL, recordings: [(url: URL, offset: Double)]) throws -> URL {
        let recordings = recordings.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !recordings.isEmpty else { throw AppError.message("No audio data was saved during the meeting.") }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError.message("FFmpeg is needed to finish the meeting recording. Install it with Homebrew and reopen the app.")
        }
        let output = folder.appendingPathComponent("audio.m4a")
        let stagedOutput = folder.appendingPathComponent("audio-mix-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: stagedOutput) }
        var arguments = ["-y"]
        var filters: [String] = []
        for (index, recording) in recordings.enumerated() {
            arguments += ["-i", recording.url.path]
            let offset = recording.offset.isFinite ? max(0, recording.offset) : 0
            let delay = Int((offset * 1000).rounded())
            // amix mixes samples without filling timestamp gaps. Insert real
            // silence so later sources and the transcript share the same clock.
            filters.append("[\(index):a]asetpts=PTS-STARTPTS,adelay=\(delay):all=1[source\(index)]")
        }
        let inputs = recordings.indices.map { "[source\($0)]" }.joined()
        filters.append("\(inputs)amix=inputs=\(recordings.count):duration=longest:dropout_transition=0[audio]")
        arguments += ["-filter_complex", filters.joined(separator: ";"), "-map", "[audio]",
                      "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", stagedOutput.path]
        _ = try run(executable: ffmpeg, arguments: arguments)
        try validateAudioHasSignal(stagedOutput)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: stagedOutput)
        } else {
            try FileManager.default.moveItem(at: stagedOutput, to: output)
        }
        for recording in recordings { try? FileManager.default.removeItem(at: recording.url) }
        return output
    }

    private static func validateAudioHasSignal(_ url: URL) throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError.message("FFmpeg is needed to validate the saved meeting audio.")
        }
        let report = try AppDelegate.run(ffmpeg,
            ["-hide_banner", "-nostats", "-i", url.path, "-vn", "-af", "volumedetect", "-f", "null", "-"])
        let peakLine = report.split(whereSeparator: \.isNewline).first { $0.contains("max_volume:") }
        let peakToken = peakLine?.components(separatedBy: "max_volume:").last?
            .trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first
        guard let peakToken, let peakDB = Double(peakToken), peakDB.isFinite, peakDB > -80 else {
            throw MeetingAudioValidationError.noUsableSignal
        }
    }

    private static func detectSpeakers(in audio: URL) async throws -> (turns: [TranscriptSegment], warning: String?) {
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("sherpa-onnx-offline-speaker-diarization"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return ([], "The speaker detection engine is missing.")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscribeToText/speaker-models", isDirectory: true)
        let segmentationDir = support.appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0", isDirectory: true)
        let segmentation = segmentationDir.appendingPathComponent("model.onnx")
        let embedding = support.appendingPathComponent("wespeaker_en_voxceleb_resnet34.onnx")
        do {
            if !FileManager.default.fileExists(atPath: segmentation.path) {
                let archive = support.appendingPathComponent("speaker-segmentation.tar.bz2")
                try await downloadModel(from: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!, to: archive) { _ in }
                try FileManager.default.createDirectory(at: segmentationDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try run(executable: "/usr/bin/tar", arguments: ["-xjf", archive.path, "-C", segmentationDir.deletingLastPathComponent().path])
                try? FileManager.default.removeItem(at: archive)
            }
            if !FileManager.default.fileExists(atPath: embedding.path) {
                try await downloadModel(from: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx")!, to: embedding) { _ in }
            }
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw AppError.message("FFmpeg is required to prepare the speaker-detection audio.")
            }
            _ = try run(executable: ffmpeg, arguments: ["-y", "-i", audio.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path])
            let result = try run(executable: executable.path,
                                 arguments: ["--clustering.cluster-threshold=0.95", "--segmentation.num-threads=4",
                                             "--embedding.num-threads=2", "--segmentation.pyannote-model=\(segmentation.path)",
                                             "--embedding.model=\(embedding.path)", wav.path])
            return (AppDelegate.parseDiarization(result), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private static func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AppError.message(String(text.suffix(900)))
        }
        return text
    }

    private static func downloadMeetingModel(from source: URL, to destination: URL, control: OperationControl,
                                             progress: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try AppDelegate.download(source, to: destination, control: control) { fraction in
                        let percentage = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                        progress("Downloading Large v3 Turbo\(percentage)…")
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 1_000_000 else {
                        try? FileManager.default.removeItem(at: destination)
                        throw AppError.message("The live transcription model download was incomplete.")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func downloadModel(from source: URL, to destination: URL,
                                      progress: @escaping (Double?) -> Void) async throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (temporary, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.message("Model download failed with an HTTP error.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 1_000_000 else {
            throw AppError.message("The model download was incomplete.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
    }
}
