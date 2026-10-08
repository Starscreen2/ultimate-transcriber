import AppKit
import Foundation

enum ActivityKind: String, Codable {
    case recording
    case transcription
    case summary

    var title: String {
        switch self {
        case .recording: return "Recording"
        case .transcription: return "Transcription"
        case .summary: return "Meeting notes"
        }
    }
}

enum ActivityState: String, Codable {
    case recording
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
    case interrupted
}

struct ActivityItem: Codable, Identifiable {
    var id: UUID
    var kind: ActivityKind
    var title: String
    var state: ActivityState
    var detail: String
    var sourcePath: String?
    var folderPath: String?
    var modelID: String?
    var language: String?
    var detectSpeakers: Bool?
    var outputBasePath: String?
    var updatedAt: Date

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var sourceURL: URL? { sourcePath.map { URL(fileURLWithPath: $0) } }
}

final class PreemptibleWorkState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentControl: OperationControl?
    private var preempted = false
    private var canceledByUser = false

    func beginAttempt() -> OperationControl {
        lock.lock()
        let control = OperationControl()
        currentControl = control
        let cancelImmediately = preempted || canceledByUser
        lock.unlock()
        if cancelImmediately { control.cancel() }
        return control
    }

    func prepareForRetryAfterPreemption() {
        lock.lock(); defer { lock.unlock() }
        preempted = false
        currentControl = nil
    }

    func preempt() {
        lock.lock()
        preempted = true
        let control = currentControl
        lock.unlock()
        control?.cancel()
    }

    func cancel() {
        lock.lock()
        canceledByUser = true
        let control = currentControl
        lock.unlock()
        control?.cancel()
    }

    var shouldRequeue: Bool {
        lock.lock(); defer { lock.unlock() }
        return preempted && !canceledByUser
    }

    var isCanceledByUser: Bool {
        lock.lock(); defer { lock.unlock() }
        return canceledByUser
    }
}

final class ActivityCenter {
    static let shared = ActivityCenter()

    private let lock = NSLock()
    private let fileURL: URL
    private var items: [ActivityItem]
    var onChange: (() -> Void)?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscribeToText/activity", isDirectory: true)
        fileURL = support.appendingPathComponent("activity.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ActivityItem].self, from: data) {
            items = decoded.map { item in
                var recovered = item
                if recovered.state == .running { recovered.state = .paused; recovered.detail = "Interrupted; ready to resume" }
                if recovered.state == .recording { recovered.state = .interrupted; recovered.detail = "Recording was interrupted. Check the saved audio before retrying." }
                return recovered
            }
        } else {
            items = []
        }
        persist()
    }

    var snapshot: [ActivityItem] {
        lock.lock(); defer { lock.unlock() }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func add(kind: ActivityKind, title: String, state: ActivityState, detail: String,
             sourceURL: URL? = nil, folderURL: URL? = nil, modelID: String? = nil,
             language: String? = nil, detectSpeakers: Bool? = nil, outputBaseURL: URL? = nil,
             id: UUID = UUID()) -> UUID {
        lock.lock()
        items.removeAll { $0.id == id }
        items.append(ActivityItem(id: id, kind: kind, title: title, state: state, detail: detail,
            sourcePath: sourceURL?.path, folderPath: folderURL?.path, modelID: modelID,
            language: language, detectSpeakers: detectSpeakers, outputBasePath: outputBaseURL?.path,
            updatedAt: Date()))
        persistLocked()
        lock.unlock()
        notifyChange()
        return id
    }

    func update(_ id: UUID, state: ActivityState, detail: String) {
        lock.lock()
        guard let index = items.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        items[index].state = state
        items[index].detail = detail
        items[index].updatedAt = Date()
        persistLocked()
        lock.unlock()
        notifyChange()
    }

    func remove(_ id: UUID) {
        lock.lock()
        items.removeAll { $0.id == id }
        persistLocked()
        lock.unlock()
        notifyChange()
    }

    func removeFinished() {
        lock.lock()
        items.removeAll { $0.state == .completed || $0.state == .cancelled }
        persistLocked()
        lock.unlock()
        notifyChange()
    }

    func recoverableItems() -> [ActivityItem] {
        snapshot.filter { item in
            guard item.state == .queued || item.state == .paused else { return false }
            if let source = item.sourceURL { return FileManager.default.fileExists(atPath: source.path) }
            if item.kind == .summary, let folder = item.folderURL {
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.srt").path)
            }
            return false
        }
    }

    func unrecoverableItems() -> [ActivityItem] {
        snapshot.filter { item in
            guard item.state == .queued || item.state == .paused else { return false }
            switch item.kind {
            case .transcription:
                return item.sourceURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
            case .summary:
                guard let folder = item.folderURL else { return true }
                return !FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.srt").path)
            case .recording:
                return false
            }
        }
    }

    func interruptedRecordings() -> [ActivityItem] {
        snapshot.filter { $0.kind == .recording && ($0.state == .interrupted || $0.state == .paused) }
    }

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    private func persist() {
        lock.lock(); persistLocked(); lock.unlock()
    }

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Could not save transcription activity: %@", error.localizedDescription)
        }
    }
}
