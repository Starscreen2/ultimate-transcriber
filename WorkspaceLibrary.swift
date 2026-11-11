import Foundation

enum WorkspaceLibraryError: LocalizedError {
    case unreadableStore(String)

    var errorDescription: String? {
        switch self {
        case .unreadableStore(let reason):
            return "The transcript library could not be read (\(reason)). The existing file was left untouched; new library changes cannot be saved until it is repaired."
        }
    }
}

enum WorkspaceRecordKind: String, Codable {
    case transcription
    case meeting
}

struct WorkspaceLibraryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var sourcePath: String
    var outputBasePath: String
    var folderPath: String
    var modelID: String
    var language: String
    var duration: Double
    var createdAt: Date
    var updatedAt: Date
    var kind: WorkspaceRecordKind
    var segments: [TranscriptSegment]
    var speakerNames: [Int: String]
    var isDeleted: Bool
    var summaryTranscriptDigest: String? = nil

    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    var outputBaseURL: URL { URL(fileURLWithPath: outputBasePath) }
    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    var characterCount: Int {
        segments.reduce(0) { $0 + $1.text.count }
    }
}

final class WorkspaceLibrary {
    static let shared = WorkspaceLibrary()

    private let lock = NSLock()
    private let fileURL: URL
    private var entries: [WorkspaceLibraryEntry]
    private var loadFailure: String?

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscribeToText/library", isDirectory: true)
        self.init(fileURL: support.appendingPathComponent("transcriptions.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            entries = []
            loadFailure = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([WorkspaceLibraryEntry].self, from: data)
            loadFailure = nil
        } catch {
            entries = []
            loadFailure = error.localizedDescription
            NSLog("Could not load the transcript library; preserving the original file: %@", error.localizedDescription)
        }
    }

    var loadError: String? {
        lock.lock(); defer { lock.unlock() }
        return loadFailure
    }

    var snapshot: [WorkspaceLibraryEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ entry: WorkspaceLibraryEntry) throws {
        lock.lock(); defer { lock.unlock() }
        var updated = entries
        if let index = updated.firstIndex(where: { $0.id == entry.id }) {
            updated[index] = entry
        } else {
            updated.append(entry)
        }
        try persistLocked(updated)
    }

    func update(_ id: UUID, _ change: (inout WorkspaceLibraryEntry) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var updated = entries
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        updated[index].updatedAt = Date()
        try persistLocked(updated)
    }

    func delete(_ id: UUID) throws {
        try update(id) { $0.isDeleted = true }
    }

    func restore(_ id: UUID) throws {
        try update(id) { $0.isDeleted = false }
    }

    func permanentlyDelete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try persistLocked(entries.filter { $0.id != id })
    }

    func clearRecentlyDeleted() throws {
        lock.lock(); defer { lock.unlock() }
        try persistLocked(entries.filter { !$0.isDeleted })
    }

    private func persistLocked(_ updated: [WorkspaceLibraryEntry]) throws {
        if let loadFailure { throw WorkspaceLibraryError.unreadableStore(loadFailure) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
        entries = updated
    }
}
