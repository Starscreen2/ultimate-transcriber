import Foundation

enum WhisperArchiveError: LocalizedError {
    case missingVersion
    case unsupportedVersion(String)
    case invalidMetadata
    case missingMedia
    case unsupportedVideoArchive
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingVersion: return "This archive has no version file."
        case .unsupportedVersion(let value): return "Whisper archive version \(value) is not supported."
        case .invalidMetadata: return "The Whisper archive metadata could not be read."
        case .missingMedia: return "The Whisper archive does not contain its original audio."
        case .unsupportedVideoArchive: return "Whisper archive export for video files is not implemented in this build."
        case .zipFailed(let message): return "Whisper archive processing failed: \(message)"
        }
    }
}

struct ImportedWhisperArchive {
    let mediaURL: URL
    let title: String
    let modelID: String
    let language: String
    let segments: [TranscriptSegment]
    let speakerNames: [Int: String]
}

enum WhisperArchive {
    private struct ArchiveSpeaker: Codable, Equatable {
        var id: UUID
        var name: String
        var color: Int
        var emoji: String?
    }

    private struct ArchiveWord: Codable {
        var text: String
        var startTime: Int
        var endTime: Int
    }

    private struct ArchiveSegment: Codable {
        var id: UUID
        var text: String
        var start: Int
        var end: Int
        var unEven: Bool
        var favorited: Bool
        var speaker: ArchiveSpeaker?
        var words: [ArchiveWord]?
    }

    private struct TimeOffset: Codable {
        var hours = 0
        var minutes = 0
        var seconds = 0
        var milliseconds = 0
    }

    private struct ArchiveTag: Codable {
        var name: String
        var color: Int
    }

    private struct Metadata: Codable {
        var originalMediaFilename: String?
        var originalMediaExtension: String?
        var videoMediaFilename: String?
        var videoMediaExtension: String?
        var transcripts: [ArchiveSegment]
        var translatedTranscripts: [String: [ArchiveSegment]]?
        var translatedFullText: [String: String]?
        var modelLanguageID: String?
        var modelQualityID: String?
        var modelEngine: String?
        var startTimeOffset: TimeOffset?
        var dateCreated: Date?
        var dateUpdated: Date?
        var speakers: [ArchiveSpeaker]?
        var wasTranslatedToEnglish: Bool?
        var tags: [ArchiveTag]?
        var detectedLanguageRaw: String?
    }

    static func export(source: URL, segments: [TranscriptSegment], names: [Int: String],
                       modelID: String, language: String, to destination: URL) throws {
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
        guard !videoExtensions.contains(source.pathExtension.lowercased()) else {
            throw WhisperArchiveError.unsupportedVideoArchive
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AppError.message("The original media file is not available for the archive.")
        }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }

        let speakers: [Int: ArchiveSpeaker] = Dictionary(uniqueKeysWithValues:
            Set(segments.compactMap(\.speakerID)).sorted().map { id in
                (id, ArchiveSpeaker(id: UUID(), name: names[id] ?? "Speaker \(id + 1)", color: id % 8, emoji: nil))
            })
        let archiveSegments = segments.map { segment in
            ArchiveSegment(id: segment.id, text: segment.text,
                           start: milliseconds(segment.start), end: milliseconds(segment.end),
                           unEven: segment.isUneven, favorited: segment.isFavorite,
                           speaker: segment.speakerID.flatMap { speakers[$0] }, words: nil)
        }
        let now = Date()
        let metadata = Metadata(
            originalMediaFilename: source.deletingPathExtension().lastPathComponent,
            originalMediaExtension: source.pathExtension.lowercased(),
            videoMediaFilename: nil, videoMediaExtension: nil,
            transcripts: archiveSegments, translatedTranscripts: [:], translatedFullText: [:],
            modelLanguageID: language, modelQualityID: "ggml-model-whisper-\(modelID)",
            modelEngine: "whisperCPP", startTimeOffset: TimeOffset(),
            dateCreated: now, dateUpdated: now,
            speakers: speakers.keys.sorted().compactMap { speakers[$0] },
            wasTranslatedToEnglish: false, tags: [], detectedLanguageRaw: language)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        try encoder.encode(metadata).write(to: stage.appendingPathComponent("metadata.json"), options: .atomic)
        try Data("2".utf8).write(to: stage.appendingPathComponent("version"), options: .atomic)
        try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent("originalAudio"))

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryArchive = parent.appendingPathComponent(".whisper-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryArchive) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stage
        process.arguments = ["-X", "-0", "-q", temporaryArchive.path, "version", "metadata.json", "originalAudio"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WhisperArchiveError.zipFailed(message?.isEmpty == false ? message! : "zip exited with \(process.terminationStatus)")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryArchive)
        } else {
            try fileManager.moveItem(at: temporaryArchive, to: destination)
        }
    }

    static func `import`(archive: URL, destinationRoot: URL? = nil) throws -> ImportedWhisperArchive {
        let versionData = try readMember("version", from: archive)
        guard let version = String(data: versionData, encoding: .utf8) else { throw WhisperArchiveError.missingVersion }
        guard version == "1" || version == "2" else { throw WhisperArchiveError.unsupportedVersion(version) }
        let metadataData = try readMember("metadata.json", from: archive)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let metadata = try? decoder.decode(Metadata.self, from: metadataData) else {
            throw WhisperArchiveError.invalidMetadata
        }

        guard metadata.transcripts.allSatisfy({ $0.start >= 0 && $0.end >= $0.start }) else {
            throw WhisperArchiveError.invalidMetadata
        }
        let rawName = metadata.originalMediaFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = rawName?.isEmpty == false ? rawName! : archive.deletingPathExtension().lastPathComponent
        let title = URL(fileURLWithPath: originalName).lastPathComponent
        guard !title.isEmpty, title != ".", title != ".." else { throw WhisperArchiveError.invalidMetadata }
        let rawExtension = (metadata.originalMediaExtension ?? "aiff")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let safeExtension = rawExtension.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) && (1...10).contains(rawExtension.count)
            ? rawExtension : "aiff"
        let root = destinationRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscribeToText/imported-archives", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let mediaURL = folder.appendingPathComponent(title).appendingPathExtension(safeExtension)
        do {
            try writeMember("originalAudio", from: archive, to: mediaURL)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw WhisperArchiveError.missingMedia
        }

        var archiveSpeakers = metadata.speakers ?? []
        for speaker in metadata.transcripts.compactMap(\.speaker) where !archiveSpeakers.contains(where: { $0.id == speaker.id }) {
            archiveSpeakers.append(speaker)
        }
        let orderedSpeakers = archiveSpeakers.sorted { $0.id.uuidString < $1.id.uuidString }
        let speakerIDByUUID = Dictionary(uniqueKeysWithValues: orderedSpeakers.enumerated().map { ($1.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: orderedSpeakers.enumerated().map { ($0, $1.name) })
        let segments = metadata.transcripts.map { segment in
            TranscriptSegment(id: segment.id,
                              start: Double(segment.start) / 1000,
                              end: Double(segment.end) / 1000,
                              text: segment.text,
                              speakerID: segment.speaker.flatMap { speakerIDByUUID[$0.id] },
                              isFavorite: segment.favorited,
                              isUneven: segment.unEven)
        }
        let rawModelID = metadata.modelQualityID?.replacingOccurrences(of: "ggml-model-whisper-", with: "") ?? "large-v3-turbo"
        return ImportedWhisperArchive(mediaURL: mediaURL, title: mediaURL.lastPathComponent,
                                      modelID: rawModelID, language: metadata.modelLanguageID ?? "auto",
                                      segments: segments, speakerNames: names)
    }

    private static func readMember(_ name: String, from archive: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if name == "version" { throw WhisperArchiveError.missingVersion }
            let message = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WhisperArchiveError.zipFailed(message.isEmpty ? "missing \(name)" : message)
        }
        return data
    }

    private static func writeMember(_ name: String, from archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw WhisperArchiveError.zipFailed("could not create the extracted media file")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostic, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WhisperArchiveError.zipFailed(message.isEmpty ? "missing \(name)" : message)
        }
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let value = max(0, min(seconds, Double(Int.max / 1000)))
        return Int((value * 1000).rounded())
    }
}
