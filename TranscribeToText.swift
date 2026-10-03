import AppKit
import UniformTypeIdentifiers
import Darwin

#if !REGRESSION_TESTS
@main
struct TranscribeToTextApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
#endif

struct WhisperModel: Hashable {
    let id: String
    let title: String
    let file: String
    let url: URL
    let detail: String

    var localURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscribeToText/models", isDirectory: true)
        return support.appendingPathComponent(file)
    }

    var downloadSize: String {
        switch id {
        case "tiny", "tiny.en": return "75 MB"
        case "base", "base.en": return "142 MB"
        case "small", "small.en": return "466 MB"
        case "medium", "medium.en": return "1.5 GB"
        case "large-v3-turbo": return "1.6 GB"
        default: return "2.9 GB"
        }
    }

    static let choices: [WhisperModel] = {
        let specs: [(String, String, String, String)] = [
            ("tiny", "Tiny · Fastest · Multilingual", "ggml-tiny.bin", "Smallest and fastest; best for quick drafts, but has the highest error rate."),
            ("base", "Base · Fast · Multilingual", "ggml-base.bin", "Fast multilingual option; lower accuracy than Small, Medium, or Large."),
            ("small", "Small · Balanced · Multilingual", "ggml-small.bin", "Balanced speed and accuracy for many languages."),
            ("medium", "Medium · More accurate · Multilingual", "ggml-medium.bin", "Higher accuracy than Small, with slower processing and a larger download."),
            ("large-v1", "Large v1 · Legacy · Multilingual", "ggml-large-v1.bin", "Original Large model; included for comparison. Newer versions are usually better."),
            ("large-v2", "Large v2 · Stable alternative · Multilingual", "ggml-large-v2.bin", "Older Large release; can be more stable for some languages or recordings."),
            ("large-v3", "Large v3 · Highest overall accuracy", "ggml-large-v3.bin", "Best overall accuracy in many cases; about 3 GB and slower than Turbo."),
            ("large-v3-turbo", "Large v3 Turbo · Much faster", "ggml-large-v3-turbo.bin", "Much faster than Large v3 with a small accuracy tradeoff; about 1.6 GB."),
            ("tiny.en", "Tiny.en · Fastest · English only", "ggml-tiny.en.bin", "English-only Tiny model; quick, but lower accuracy than larger English models."),
            ("base.en", "Base.en · Fast · English only", "ggml-base.en.bin", "English-only Base model; faster than Small.en, with lower accuracy."),
            ("small.en", "Small.en · Balanced · English only", "ggml-small.en.bin", "English-only model with a useful speed/accuracy balance."),
            ("medium.en", "Medium.en · More accurate · English only", "ggml-medium.en.bin", "English-only Medium model; higher accuracy, with more processing time and storage."),
        ]
        return specs.map { id, title, file, detail in
            WhisperModel(id: id, title: title, file: file,
                         url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!, detail: detail)
        }
    }()

    static let vadFile = "ggml-silero-v6.2.0.bin"
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(vadFile)")!

    static func isInstalled(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 4,
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data([0x6c, 0x6d, 0x67, 0x67])
    }
}

struct TranscriptSegment {
    var start: Double
    var end: Double
    var text: String
    var speakerID: Int?
}

final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var downloadTask: URLSessionDownloadTask?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        if isCancelled { throw AppError.cancelled }
    }

    // Committing files and accepting cancellation must have a single ordering.
    func commit<T>(_ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw AppError.cancelled }
        return try action()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeProcess = process
        let activeDownload = downloadTask
        lock.unlock()
        activeDownload?.cancel()
        if let activeProcess { Self.terminate(activeProcess) }
    }

    func attach(_ process: Process) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { self.process = process }
        lock.unlock()
        if shouldCancel { Self.terminate(process) }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func detach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { downloadTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func detach(_ task: URLSessionDownloadTask) {
        lock.lock(); defer { lock.unlock() }
        if downloadTask === task { downloadTask = nil }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let filename = NSTextField(labelWithString: "No file selected")
    private let filePath = NSTextField(labelWithString: "Audio/video is converted and transcribed locally")
    private let chooseButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelDetail = NSTextField(wrappingLabelWithString: "")
    private let downloadModelButton = NSButton(title: "Download Model", target: nil, action: nil)
    private let languagePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customLanguage = NSTextField()
    private let status = NSTextField(labelWithString: "Choose an audio or video file to get started.")
    private let transcript = NSTextView()
    private let copyTranscriptButton = NSButton(title: "Copy Transcript", target: nil, action: nil)
    private let exportTranscriptButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let spinner = NSProgressIndicator()
    private let transcribeButton = NSButton(title: "Transcribe", target: nil, action: nil)
    private let showResultsButton = NSButton(title: "Show Results", target: nil, action: nil)
    private let summaryButton = NSButton(title: "Generate Local Notes…", target: nil, action: nil)
    private let stopMeetingButton = NSButton(title: "Stop Meeting", target: nil, action: nil)
    private let openRecordingsButton = NSButton(title: "Open Recordings", target: nil, action: nil)
    private let meetingSettingsButton = NSButton(title: "Meeting Settings…", target: nil, action: nil)
    private let microphoneCaptureToggle = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
    private let systemAudioCaptureToggle = NSButton(checkboxWithTitle: "System Audio", target: nil, action: nil)
    private let meetingSettingsNote = NSTextField(wrappingLabelWithString: "")
    private var meetingSettingsWindow: NSWindow?
    private let speakerToggle = NSButton(checkboxWithTitle: "Detect speakers", target: nil, action: nil)
    private let speakerEditors = NSStackView()
    private var selectedFile: URL?
    private var resultFolder: URL?
    private var meetingResult: MeetingSessionResult?
    private var summaryURL: URL?
    private var summaryGenerationID: UUID?
    private var activeSummaryOperation: OperationControl?
    private var meetingStatusItem: NSStatusItem?
    private let meetingController = MeetingCaptureController()
    private var waitingForMeetingStopBeforeQuit = false
    private var waitingForMeetingNotesBeforeQuit = false
    private var waitingForOperationBeforeQuit = false
    private var outputBase: URL?
    private var transcriptSegments: [TranscriptSegment] = []
    private var speakerNames: [Int: String] = [:]
    private var speakerFields: [Int: NSTextField] = [:]
    private var transcriptTopConstraint: NSLayoutConstraint?
    private var previewContainer: NSBox?
    private var isBusy = false
    private var activeOperation: OperationControl?
    private enum BusyKind { case transcription, modelDownload }
    private var busyKind: BusyKind?

    private enum TranscriptExportFormat: CaseIterable {
        case plainText
        case srt
        case vtt

        var menuTitle: String {
            switch self {
            case .plainText: return "Plain Text (.txt)"
            case .srt: return "SubRip Subtitles (.srt)"
            case .vtt: return "WebVTT Subtitles (.vtt)"
            }
        }

        var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .srt: return "srt"
            case .vtt: return "vtt"
            }
        }

        var contentType: UTType {
            switch self {
            case .plainText: return .plainText
            case .srt: return UTType(filenameExtension: "srt", conformingTo: .text) ?? .plainText
            case .vtt: return UTType(filenameExtension: "vtt", conformingTo: .text) ?? .plainText
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        configureMeetingBadge()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingForMeetingStopBeforeQuit || waitingForOperationBeforeQuit { return .terminateLater }
        if let operation = activeOperation ?? activeSummaryOperation {
            waitingForOperationBeforeQuit = true
            operation.cancel()
            setBusyControls(isBusy)
            updateMeetingBadgeMenu()
            return .terminateLater
        }
        guard meetingController.inProgress else { return .terminateNow }
        waitingForMeetingStopBeforeQuit = true
        meetingIsStopping = true
        updateMeetingBadgeMenu()
        updateMeetingCaptureControls()
        meetingController.stop()
        return .terminateLater
    }

    private var meetingIsPreparing = false
    private var meetingIsActive = false
    private var meetingIsStopping = false

    private var meetingInProgress: Bool {
        meetingIsPreparing || meetingIsActive || meetingIsStopping || meetingController.inProgress
    }

    private var isTerminating: Bool {
        waitingForOperationBeforeQuit || waitingForMeetingStopBeforeQuit
    }

    private func clearMeetingNotes() {
        activeSummaryOperation?.cancel()
        activeSummaryOperation = nil
        summaryGenerationID = nil
        summaryURL = nil
        meetingResult = nil
        summaryButton.isHidden = true
        summaryButton.isEnabled = false
        summaryButton.title = "Generate Local Notes…"
        summaryButton.action = #selector(generateMeetingNotes)
    }

    private var meetingMicrophoneEnabled: Bool {
        UserDefaults.standard.object(forKey: "MeetingCaptureMicrophone") as? Bool ?? true
    }

    private var meetingSystemAudioEnabled: Bool {
        UserDefaults.standard.object(forKey: "MeetingCaptureSystemAudio") as? Bool ?? true
    }

    private var supportsSystemAudioCapture: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private var meetingRecordingsFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: "MeetingOutputRoot") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func configureMeetingBadge() {
        meetingStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        meetingStatusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Meeting Capture")
        meetingStatusItem?.button?.toolTip = "Meeting Capture"
        updateMeetingBadgeMenu()

        meetingController.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.status.stringValue = message }
        }
        meetingController.onStateChange = { [weak self] active in
            DispatchQueue.main.async {
                guard let self else { return }
                self.meetingIsPreparing = false
                self.meetingIsActive = active
                self.meetingIsStopping = false
                self.updateMeetingBadgeMenu()
                self.updateMeetingCaptureControls()
            }
        }
        meetingController.onLiveSegments = { [weak self] segments in
            DispatchQueue.main.async {
                guard let self else { return }
                self.transcriptSegments = segments
                self.transcript.string = Self.renderTranscript(segments, names: [:])
                self.transcript.textColor = .labelColor
                self.transcript.scrollRangeToVisible(NSRange(location: self.transcript.string.utf16.count, length: 0))
                self.updateTranscriptActionButtons()
            }
        }
        meetingController.onFinished = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.meetingResult = result
                self.resultFolder = result.folder
                self.outputBase = result.transcriptBase
                self.transcriptSegments = result.segments
                self.speakerNames = Dictionary(uniqueKeysWithValues: result.speakerIDs.enumerated().map { ($1, "Speaker \($0 + 1)") })
                self.summaryURL = nil
                self.transcript.string = Self.renderTranscript(result.segments, names: self.speakerNames)
                self.transcript.textColor = .labelColor
                self.updateTranscriptActionButtons()
                self.updateSpeakerEditors()
                self.showResultsButton.isHidden = false
                self.summaryButton.isHidden = false
                self.summaryButton.isEnabled = true
                self.summaryButton.title = "Generate Local Notes…"
                self.summaryButton.action = #selector(self.generateMeetingNotes)
                if let warning = result.speakerWarning {
                    self.status.stringValue = "Meeting saved with a processing warning: \(warning)"
                } else {
                    self.status.stringValue = "Meeting saved with \(result.speakerIDs.count) speaker labels."
                }
                self.updateMeetingBadgeMenu()
                self.updateMeetingCaptureControls()
                if LocalMeetingSummarizer.isModelInstalled {
                    self.waitingForMeetingNotesBeforeQuit = self.waitingForMeetingStopBeforeQuit
                    self.generateMeetingNotes()
                }
                if self.waitingForMeetingStopBeforeQuit && !self.waitingForMeetingNotesBeforeQuit {
                    self.waitingForMeetingStopBeforeQuit = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        meetingController.onFailure = { [weak self] message, preservedFolder in
            DispatchQueue.main.async {
                guard let self else { return }
                self.meetingIsPreparing = false
                self.meetingIsActive = false
                self.meetingIsStopping = false
                self.status.stringValue = message
                if let preservedFolder {
                    self.resultFolder = preservedFolder
                    self.showResultsButton.isHidden = false
                }
                self.updateMeetingBadgeMenu()
                self.updateMeetingCaptureControls()
                if self.waitingForMeetingStopBeforeQuit {
                    self.waitingForMeetingStopBeforeQuit = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    private func updateMeetingBadgeMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let startTitle = meetingIsPreparing ? "Preparing Meeting…" : "Start Meeting"
        let start = NSMenuItem(title: startTitle, action: #selector(startMeetingFromBadge), keyEquivalent: "")
        start.target = self
        start.isEnabled = !meetingInProgress && !isBusy && !isTerminating
        menu.addItem(start)

        let stop = NSMenuItem(title: meetingIsStopping ? "Finishing Meeting…" : "Stop Meeting",
                              action: #selector(stopMeetingFromBadge), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = meetingInProgress && !meetingIsStopping
        menu.addItem(stop)

        let results = NSMenuItem(title: "Open Results", action: #selector(showResults), keyEquivalent: "")
        results.target = self
        results.isEnabled = resultFolder != nil
        menu.addItem(results)

        let recordings = NSMenuItem(title: "Open Recordings", action: #selector(openMeetingRecordings), keyEquivalent: "")
        recordings.target = self
        recordings.isEnabled = meetingRecordingsFolder != nil
        menu.addItem(recordings)

        let openApp = NSMenuItem(title: "Open App", action: #selector(openAppFromBadge), keyEquivalent: "")
        openApp.target = self
        menu.addItem(openApp)

        let settings = NSMenuItem(title: "Meeting Settings…", action: #selector(openMeetingSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Transcribe to Text", action: #selector(quitFromBadge), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        meetingStatusItem?.menu = menu
    }

    @objc private func startMeetingFromBadge() {
        guard !meetingInProgress, !isBusy, !isTerminating else { return }
        guard meetingMicrophoneEnabled || (meetingSystemAudioEnabled && supportsSystemAudioCapture) else {
            status.stringValue = "Turn on at least one available audio source in Meeting Settings."
            openAppFromBadge()
            openMeetingSettings()
            return
        }
        if let folder = meetingRecordingsFolder {
            beginMeeting(at: folder)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose where to save meeting recordings"
        panel.message = "Each meeting will get its own folder with audio, transcript, and notes."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let folder = panel.url {
            UserDefaults.standard.set(folder.path, forKey: "MeetingOutputRoot")
            beginMeeting(at: folder)
        }
    }

    private func beginMeeting(at folder: URL) {
        meetingIsPreparing = true
        clearMeetingNotes()
        resultFolder = nil
        showResultsButton.isHidden = true
        outputBase = nil
        transcriptSegments = []
        speakerNames = [:]
        updateTranscriptActionButtons()
        transcript.string = "Live transcript will appear here as speech is recognized. Whisper processes short chunks, so the first text may take several seconds."
        transcript.textColor = .secondaryLabelColor
        updateSpeakerEditors()
        summaryButton.isHidden = true
        summaryButton.isEnabled = false
        summaryButton.title = "Generate Local Notes…"
        summaryButton.action = #selector(generateMeetingNotes)
        status.stringValue = "Preparing the meeting session…"
        updateMeetingBadgeMenu()
        updateMeetingCaptureControls()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        meetingController.start(meetingsRoot: folder,
                                includeMicrophone: meetingMicrophoneEnabled,
                                includeSystemAudio: meetingSystemAudioEnabled && supportsSystemAudioCapture)
    }

    @objc private func stopMeetingFromBadge() {
        guard meetingInProgress, !meetingIsStopping else { return }
        meetingIsStopping = true
        updateMeetingBadgeMenu()
        updateMeetingCaptureControls()
        meetingController.stop()
    }

    private func updateMeetingCaptureControls() {
        stopMeetingButton.isHidden = !meetingInProgress
        stopMeetingButton.isEnabled = meetingInProgress && !meetingIsStopping
        stopMeetingButton.title = meetingIsStopping ? "Saving Meeting…" : "Stop Meeting"
        openRecordingsButton.isEnabled = meetingRecordingsFolder != nil
        setBusyControls(isBusy)
        updateModelDownloadButton()
    }

    @objc private func openMeetingSettings() {
        if meetingSettingsWindow == nil {
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 260),
                                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settingsWindow.title = "Meeting Settings"
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.center()

            let title = NSTextField(labelWithString: "Meeting audio sources")
            title.font = .boldSystemFont(ofSize: 17)
            let intro = NSTextField(wrappingLabelWithString: "Choose which sources are used for new meeting sessions.")
            intro.font = .systemFont(ofSize: 12)
            intro.textColor = .secondaryLabelColor
            let microphoneDetail = NSTextField(wrappingLabelWithString: "Records nearby voices through the Mac microphone.")
            microphoneDetail.font = .systemFont(ofSize: 11)
            microphoneDetail.textColor = .secondaryLabelColor
            let systemAudioDetail = NSTextField(wrappingLabelWithString: "Captures sound playing through the Mac with an audio-only Core Audio tap. No screen video is captured.")
            systemAudioDetail.font = .systemFont(ofSize: 11)
            systemAudioDetail.textColor = .secondaryLabelColor
            systemAudioDetail.maximumNumberOfLines = 2
            systemAudioDetail.lineBreakMode = .byWordWrapping
            meetingSettingsNote.font = .systemFont(ofSize: 11)
            meetingSettingsNote.textColor = .secondaryLabelColor
            meetingSettingsNote.maximumNumberOfLines = 2
            meetingSettingsNote.lineBreakMode = .byWordWrapping

            microphoneCaptureToggle.target = self
            microphoneCaptureToggle.action = #selector(meetingAudioSourceChanged(_:))
            microphoneCaptureToggle.tag = 1
            systemAudioCaptureToggle.target = self
            systemAudioCaptureToggle.action = #selector(meetingAudioSourceChanged(_:))
            systemAudioCaptureToggle.tag = 2
            systemAudioCaptureToggle.isEnabled = supportsSystemAudioCapture
            if supportsSystemAudioCapture {
                meetingSettingsNote.stringValue = "These settings apply to meetings you start next. Capture and transcription stay on this Mac."
            } else {
                meetingSettingsNote.stringValue = "System audio capture requires macOS 14.2 or later. Microphone capture works on macOS 13 and later."
            }

            let content = NSView()
            settingsWindow.contentView = content
            [title, intro, microphoneCaptureToggle, microphoneDetail, systemAudioCaptureToggle,
             systemAudioDetail, meetingSettingsNote].forEach {
                content.addSubview($0)
                $0.translatesAutoresizingMaskIntoConstraints = false
            }
            NSLayoutConstraint.activate([
                title.leftAnchor.constraint(equalTo: content.leftAnchor, constant: 22),
                title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
                intro.leftAnchor.constraint(equalTo: title.leftAnchor),
                intro.rightAnchor.constraint(equalTo: content.rightAnchor, constant: -22),
                intro.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
                microphoneCaptureToggle.leftAnchor.constraint(equalTo: title.leftAnchor),
                microphoneCaptureToggle.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 15),
                microphoneDetail.leftAnchor.constraint(equalTo: microphoneCaptureToggle.leftAnchor, constant: 22),
                microphoneDetail.rightAnchor.constraint(equalTo: intro.rightAnchor),
                microphoneDetail.topAnchor.constraint(equalTo: microphoneCaptureToggle.bottomAnchor, constant: 2),
                systemAudioCaptureToggle.leftAnchor.constraint(equalTo: title.leftAnchor),
                systemAudioCaptureToggle.topAnchor.constraint(equalTo: microphoneDetail.bottomAnchor, constant: 12),
                systemAudioDetail.leftAnchor.constraint(equalTo: systemAudioCaptureToggle.leftAnchor, constant: 22),
                systemAudioDetail.rightAnchor.constraint(equalTo: intro.rightAnchor),
                systemAudioDetail.topAnchor.constraint(equalTo: systemAudioCaptureToggle.bottomAnchor, constant: 2),
                meetingSettingsNote.leftAnchor.constraint(equalTo: title.leftAnchor),
                meetingSettingsNote.rightAnchor.constraint(equalTo: intro.rightAnchor),
                meetingSettingsNote.topAnchor.constraint(equalTo: systemAudioDetail.bottomAnchor, constant: 10),
            ])
            meetingSettingsWindow = settingsWindow
        }

        microphoneCaptureToggle.state = meetingMicrophoneEnabled ? .on : .off
        systemAudioCaptureToggle.state = supportsSystemAudioCapture && meetingSystemAudioEnabled ? .on : .off
        meetingSettingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func meetingAudioSourceChanged(_ sender: NSButton) {
        if sender.tag == 1 {
            UserDefaults.standard.set(sender.state == .on, forKey: "MeetingCaptureMicrophone")
        } else if sender.tag == 2 {
            UserDefaults.standard.set(sender.state == .on, forKey: "MeetingCaptureSystemAudio")
        }
        meetingSettingsNote.stringValue = meetingMicrophoneEnabled || (meetingSystemAudioEnabled && supportsSystemAudioCapture)
            ? "These settings apply to meetings you start next. Capture and transcription stay on this Mac."
            : "Turn on at least one available audio source before starting a meeting."
    }

    @objc private func quitFromBadge() {
        NSApp.terminate(nil)
    }

    @objc private func generateMeetingNotes() {
        guard let result = meetingResult, activeSummaryOperation == nil, !meetingInProgress, !isBusy else { return }
        let generationID = UUID()
        let operation = OperationControl()
        summaryGenerationID = generationID
        activeSummaryOperation = operation
        summaryButton.isEnabled = false
        summaryButton.title = "Generating Notes…"
        updateModelDownloadButton()
        LocalMeetingSummarizer.generate(folder: result.folder, segments: result.segments, names: speakerNames,
                                        control: operation,
                                        progress: { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.summaryGenerationID == generationID else { return }
                self.status.stringValue = message
            }
        }, completion: { [weak self] completion in
            guard let self, self.summaryGenerationID == generationID else { return }
            self.activeSummaryOperation = nil
            self.updateModelDownloadButton()
            self.summaryButton.isEnabled = true
            switch completion {
            case .success(let url):
                self.summaryURL = url
                self.summaryButton.title = "Open Summary"
                self.summaryButton.action = #selector(self.openMeetingSummary)
                self.status.stringValue = "Local meeting notes saved."
            case .failure(let error):
                self.summaryButton.title = LocalMeetingSummarizer.isModelInstalled ? "Retry Local Notes" : "Generate Local Notes…"
                self.summaryButton.action = #selector(self.generateMeetingNotes)
                self.status.stringValue = "Meeting audio and transcript are saved. Notes could not be generated: \(error.localizedDescription)"
            }
            if self.waitingForMeetingNotesBeforeQuit || self.waitingForOperationBeforeQuit {
                self.waitingForMeetingNotesBeforeQuit = false
                self.waitingForMeetingStopBeforeQuit = false
                self.waitingForOperationBeforeQuit = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        })
    }

    @objc private func openMeetingSummary() {
        if let summaryURL { NSWorkspace.shared.open(summaryURL) }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Transcribe to Text"
        window.minSize = NSSize(width: 720, height: 700)
        window.center()

        filename.font = .boldSystemFont(ofSize: 14)
        filename.lineBreakMode = .byTruncatingMiddle
        filePath.font = .systemFont(ofSize: 11)
        filePath.textColor = .secondaryLabelColor
        filePath.lineBreakMode = .byTruncatingMiddle
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        WhisperModel.choices.forEach { modelPicker.addItem(withTitle: $0.title) }
        modelPicker.selectItem(at: 6)
        modelDetail.stringValue = WhisperModel.choices[6].detail + " First download is about 3 GB."
        modelDetail.font = .systemFont(ofSize: 11)
        modelDetail.textColor = .secondaryLabelColor
        ["Auto detect", "English", "Spanish", "French", "German", "Chinese", "Japanese", "Korean", "Other…"]
            .forEach { languagePicker.addItem(withTitle: $0) }
        customLanguage.placeholderString = "Language code (e.g. it)"
        customLanguage.isHidden = true

        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        transcribeButton.target = self
        transcribeButton.action = #selector(transcriptionButtonClicked)
        transcribeButton.bezelStyle = .rounded
        transcribeButton.keyEquivalent = "\r"
        transcribeButton.isEnabled = false
        stopMeetingButton.target = self
        stopMeetingButton.action = #selector(stopMeetingFromBadge)
        stopMeetingButton.bezelStyle = .rounded
        stopMeetingButton.controlSize = .small
        stopMeetingButton.isHidden = true
        openRecordingsButton.target = self
        openRecordingsButton.action = #selector(openMeetingRecordings)
        openRecordingsButton.bezelStyle = .rounded
        openRecordingsButton.controlSize = .small
        openRecordingsButton.isEnabled = meetingRecordingsFolder != nil
        openRecordingsButton.toolTip = "Open the folder containing all saved meeting sessions"
        meetingSettingsButton.target = self
        meetingSettingsButton.action = #selector(openMeetingSettings)
        meetingSettingsButton.bezelStyle = .rounded
        meetingSettingsButton.controlSize = .small
        downloadModelButton.target = self
        downloadModelButton.action = #selector(downloadSelectedModel)
        downloadModelButton.bezelStyle = .rounded
        downloadModelButton.controlSize = .small
        showResultsButton.target = self
        showResultsButton.action = #selector(showResults)
        showResultsButton.isHidden = true
        summaryButton.target = self
        summaryButton.action = #selector(generateMeetingNotes)
        summaryButton.isHidden = true
        summaryButton.isEnabled = false
        summaryButton.bezelStyle = .rounded
        summaryButton.controlSize = .small
        copyTranscriptButton.target = self
        copyTranscriptButton.action = #selector(copyTranscript)
        copyTranscriptButton.bezelStyle = .rounded
        copyTranscriptButton.controlSize = .small
        copyTranscriptButton.toolTip = "Copy the transcript with timestamps and speaker names"
        exportTranscriptButton.addItem(withTitle: "Export…")
        TranscriptExportFormat.allCases.forEach { exportTranscriptButton.addItem(withTitle: $0.menuTitle) }
        exportTranscriptButton.selectItem(at: 0)
        exportTranscriptButton.target = self
        exportTranscriptButton.action = #selector(exportTranscript(_:))
        exportTranscriptButton.controlSize = .small
        exportTranscriptButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        exportTranscriptButton.toolTip = "Save the transcript as TXT, SRT, or WebVTT"
        copyTranscriptButton.isEnabled = false
        copyTranscriptButton.widthAnchor.constraint(equalToConstant: 112).isActive = true
        exportTranscriptButton.isEnabled = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.stopAnimation(nil)

        languagePicker.target = self
        languagePicker.action = #selector(languageChanged)
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        modelChanged()

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        transcript.string = "Your transcript will appear here."
        transcript.textColor = .tertiaryLabelColor
        transcript.drawsBackground = false
        let transcriptScroll = NSScrollView()
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.drawsBackground = false
        transcriptScroll.autoresizingMask = [.width, .height]
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Transcribe to Text")
        heading.font = .boldSystemFont(ofSize: 23)
        let subheading = NSTextField(labelWithString: "Private, on-device transcription powered by Whisper")
        subheading.textColor = .secondaryLabelColor
        subheading.font = .systemFont(ofSize: 13)

        let inputBox = groupBox("Input and settings", content: NSView())
        let fileCaption = caption("Media file")
        let modelCaption = caption("Whisper model")
        let languageCaption = caption("Language")
        let divider = separator()
        modelDetail.maximumNumberOfLines = 2
        modelDetail.lineBreakMode = .byWordWrapping
        let statusIcon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) ?? NSImage())
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        let statusRow = NSView()
        statusRow.addSubview(statusIcon)
        statusRow.addSubview(status)

        let previewBox = groupBox("Transcript preview", content: NSView())
        previewContainer = previewBox
        let speakerNote = NSTextField(wrappingLabelWithString: "Speaker labels are automatic estimates. Rename them above; TXT, SRT, and VTT update automatically.")
        speakerNote.textColor = .secondaryLabelColor
        speakerNote.font = .systemFont(ofSize: 11)
        speakerNote.maximumNumberOfLines = 2
        speakerNote.lineBreakMode = .byTruncatingTail
        let footer = NSTextField(labelWithString: "Exports TXT, SRT, and VTT beside the source file. Media stays on this Mac.")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor

        window.contentView = NSView()
        let root = window.contentView!
        [heading, subheading, inputBox, fileCaption, filename, filePath, chooseButton,
         divider, modelCaption, modelPicker, modelDetail, languageCaption, languagePicker,
         customLanguage, speakerToggle, transcribeButton, spinner, showResultsButton, statusRow,
         summaryButton, downloadModelButton, speakerEditors, previewBox, transcriptScroll, speakerNote, footer,
         stopMeetingButton, openRecordingsButton, meetingSettingsButton, copyTranscriptButton,
         exportTranscriptButton].forEach { root.addSubview($0) }

        [heading, subheading, inputBox, fileCaption, filename, filePath, chooseButton,
         divider, modelCaption, modelPicker, modelDetail, languageCaption, languagePicker,
         customLanguage, speakerToggle, transcribeButton, spinner, showResultsButton, statusRow,
         summaryButton, downloadModelButton, speakerEditors, stopMeetingButton, openRecordingsButton, meetingSettingsButton,
         statusIcon, status, previewBox, transcriptScroll, speakerNote, footer,
         copyTranscriptButton, exportTranscriptButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        inputBox.heightAnchor.constraint(equalToConstant: 250).isActive = true
        speakerToggle.state = .on
        speakerToggle.font = .systemFont(ofSize: 12)
        speakerToggle.toolTip = "Use a separate on-device model to identify who spoke when. Speaker detection adds its own first-run model downloads."
        speakerEditors.orientation = .horizontal
        speakerEditors.alignment = .centerY
        speakerEditors.spacing = 10
        speakerEditors.isHidden = true

        NSLayoutConstraint.activate([
            heading.leftAnchor.constraint(equalTo: root.leftAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            meetingSettingsButton.rightAnchor.constraint(equalTo: root.rightAnchor, constant: -24),
            meetingSettingsButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            openRecordingsButton.rightAnchor.constraint(equalTo: meetingSettingsButton.leftAnchor, constant: -8),
            openRecordingsButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            stopMeetingButton.rightAnchor.constraint(equalTo: openRecordingsButton.leftAnchor, constant: -8),
            stopMeetingButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            subheading.leftAnchor.constraint(equalTo: heading.leftAnchor),
            subheading.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),

            inputBox.leftAnchor.constraint(equalTo: root.leftAnchor, constant: 24),
            inputBox.rightAnchor.constraint(equalTo: root.rightAnchor, constant: -24),
            inputBox.topAnchor.constraint(equalTo: subheading.bottomAnchor, constant: 16),

            fileCaption.leftAnchor.constraint(equalTo: inputBox.leftAnchor, constant: 16),
            fileCaption.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 25),
            filename.leftAnchor.constraint(equalTo: fileCaption.rightAnchor, constant: 12),
            filename.centerYAnchor.constraint(equalTo: fileCaption.centerYAnchor),
            filename.rightAnchor.constraint(lessThanOrEqualTo: chooseButton.leftAnchor, constant: -12),
            chooseButton.rightAnchor.constraint(equalTo: inputBox.rightAnchor, constant: -16),
            chooseButton.centerYAnchor.constraint(equalTo: fileCaption.centerYAnchor),
            filePath.leftAnchor.constraint(equalTo: fileCaption.leftAnchor),
            filePath.rightAnchor.constraint(equalTo: chooseButton.rightAnchor),
            filePath.topAnchor.constraint(equalTo: fileCaption.bottomAnchor, constant: 4),

            divider.leftAnchor.constraint(equalTo: fileCaption.leftAnchor),
            divider.rightAnchor.constraint(equalTo: chooseButton.rightAnchor),
            divider.topAnchor.constraint(equalTo: filePath.bottomAnchor, constant: 12),

            modelCaption.leftAnchor.constraint(equalTo: fileCaption.leftAnchor),
            modelCaption.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            modelCaption.rightAnchor.constraint(equalTo: modelPicker.rightAnchor),
            modelPicker.leftAnchor.constraint(equalTo: modelCaption.leftAnchor),
            modelPicker.topAnchor.constraint(equalTo: modelCaption.bottomAnchor, constant: 5),
            modelPicker.widthAnchor.constraint(equalTo: inputBox.widthAnchor, multiplier: 0.55, constant: -20),
            modelDetail.leftAnchor.constraint(equalTo: modelPicker.leftAnchor),
            modelDetail.rightAnchor.constraint(equalTo: modelPicker.rightAnchor),
            modelDetail.topAnchor.constraint(equalTo: modelPicker.bottomAnchor, constant: 4),
            downloadModelButton.leftAnchor.constraint(equalTo: modelPicker.leftAnchor),
            downloadModelButton.topAnchor.constraint(equalTo: modelDetail.bottomAnchor, constant: 5),

            languageCaption.leftAnchor.constraint(equalTo: modelPicker.rightAnchor, constant: 22),
            languageCaption.topAnchor.constraint(equalTo: modelCaption.topAnchor),
            languageCaption.rightAnchor.constraint(equalTo: chooseButton.rightAnchor),
            languagePicker.leftAnchor.constraint(equalTo: languageCaption.leftAnchor),
            languagePicker.rightAnchor.constraint(equalTo: languageCaption.rightAnchor),
            languagePicker.topAnchor.constraint(equalTo: languageCaption.bottomAnchor, constant: 5),
            customLanguage.leftAnchor.constraint(equalTo: languagePicker.leftAnchor),
            customLanguage.rightAnchor.constraint(equalTo: languagePicker.rightAnchor),
            customLanguage.topAnchor.constraint(equalTo: languagePicker.bottomAnchor, constant: 4),

            speakerToggle.leftAnchor.constraint(equalTo: fileCaption.leftAnchor),
            speakerToggle.topAnchor.constraint(equalTo: downloadModelButton.bottomAnchor, constant: 8),
            transcribeButton.rightAnchor.constraint(equalTo: chooseButton.rightAnchor),
            transcribeButton.widthAnchor.constraint(equalToConstant: 112),
            transcribeButton.centerYAnchor.constraint(equalTo: speakerToggle.centerYAnchor),
            speakerToggle.rightAnchor.constraint(lessThanOrEqualTo: spinner.leftAnchor, constant: -8),
            spinner.rightAnchor.constraint(equalTo: transcribeButton.leftAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: speakerToggle.centerYAnchor),
            showResultsButton.rightAnchor.constraint(equalTo: transcribeButton.leftAnchor, constant: -8),
            showResultsButton.centerYAnchor.constraint(equalTo: transcribeButton.centerYAnchor),
            summaryButton.rightAnchor.constraint(equalTo: showResultsButton.leftAnchor, constant: -8),
            summaryButton.centerYAnchor.constraint(equalTo: transcribeButton.centerYAnchor),
            transcribeButton.bottomAnchor.constraint(lessThanOrEqualTo: inputBox.bottomAnchor, constant: -14),

            statusRow.leftAnchor.constraint(equalTo: inputBox.leftAnchor),
            statusRow.rightAnchor.constraint(equalTo: inputBox.rightAnchor),
            statusRow.topAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: 10),
            statusRow.heightAnchor.constraint(equalToConstant: 22),
            statusIcon.leftAnchor.constraint(equalTo: statusRow.leftAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
            status.leftAnchor.constraint(equalTo: statusIcon.rightAnchor, constant: 8),
            status.rightAnchor.constraint(equalTo: exportTranscriptButton.leftAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            copyTranscriptButton.rightAnchor.constraint(equalTo: root.rightAnchor, constant: -24),
            copyTranscriptButton.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            exportTranscriptButton.rightAnchor.constraint(equalTo: copyTranscriptButton.leftAnchor, constant: -8),
            exportTranscriptButton.centerYAnchor.constraint(equalTo: copyTranscriptButton.centerYAnchor),

            previewBox.leftAnchor.constraint(equalTo: root.leftAnchor, constant: 24),
            previewBox.rightAnchor.constraint(equalTo: root.rightAnchor, constant: -24),
            previewBox.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 8),
            previewBox.bottomAnchor.constraint(equalTo: speakerNote.topAnchor, constant: -10),
            transcriptScroll.leftAnchor.constraint(equalTo: previewBox.leftAnchor, constant: 16),
            transcriptScroll.rightAnchor.constraint(equalTo: previewBox.rightAnchor, constant: -16),
            transcriptScroll.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -12),
            speakerEditors.leftAnchor.constraint(equalTo: previewBox.leftAnchor, constant: 16),
            speakerEditors.rightAnchor.constraint(lessThanOrEqualTo: previewBox.rightAnchor, constant: -16),
            speakerEditors.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 26),
            previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

            speakerNote.leftAnchor.constraint(equalTo: root.leftAnchor, constant: 24),
            speakerNote.rightAnchor.constraint(equalTo: root.rightAnchor, constant: -24),
            speakerNote.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leftAnchor.constraint(equalTo: root.leftAnchor, constant: 24),
            footer.rightAnchor.constraint(equalTo: root.rightAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        let transcriptTopWithoutSpeakers = transcriptScroll.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 28)
        transcriptTopConstraint = transcriptTopWithoutSpeakers
        transcriptTopWithoutSpeakers.isActive = true
        speakerToggle.target = self
        speakerToggle.action = #selector(speakerDetectionChanged)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseFile() {
        guard !isBusy, !meetingInProgress, !isTerminating else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        if panel.runModal() == .OK, let url = panel.url {
            clearMeetingNotes()
            selectedFile = url
            transcribeButton.isEnabled = true
            filename.stringValue = url.lastPathComponent
            filePath.stringValue = url.path
            transcript.string = "Your transcript will appear here."
            transcript.textColor = .tertiaryLabelColor
            transcriptSegments = []
            speakerNames = [:]
            outputBase = nil
            updateSpeakerEditors()
            resultFolder = nil
            showResultsButton.isHidden = true
            status.stringValue = "Ready to transcribe."
            updateTranscriptActionButtons()
            updateMeetingBadgeMenu()
        }
    }

    @objc private func languageChanged() {
        customLanguage.isHidden = languagePicker.indexOfSelectedItem != 8
    }

    @objc private func modelChanged() {
        let selected = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        modelDetail.stringValue = selected.detail + " First download: \(selected.downloadSize)."
        if selected.id.hasSuffix(".en") {
            languagePicker.selectItem(at: 1)
            modelDetail.stringValue += " Language is set to English for this model."
        }
        languagePicker.isEnabled = !isBusy && !meetingInProgress && !selected.id.hasSuffix(".en")
        languageChanged()
        updateModelDownloadButton()
    }

    private func updateModelDownloadButton() {
        let selected = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        if busyKind == .modelDownload {
            downloadModelButton.title = activeOperation?.isCancelled == true ? "Canceling…" : "Cancel Download"
            downloadModelButton.isEnabled = activeOperation?.isCancelled == false
        } else if WhisperModel.isInstalled(at: selected.localURL) {
            downloadModelButton.title = "Model Downloaded"
            downloadModelButton.isEnabled = false
        } else {
            downloadModelButton.title = "Download Model (\(selected.downloadSize))"
            downloadModelButton.isEnabled = activeOperation == nil && activeSummaryOperation == nil && !meetingInProgress && !isTerminating
        }
    }

    @objc private func downloadSelectedModel() {
        if busyKind == .modelDownload, let operation = activeOperation {
            downloadModelButton.title = "Canceling…"
            downloadModelButton.isEnabled = false
            status.stringValue = "Cancelling model download…"
            operation.cancel()
            return
        }
        guard activeOperation == nil, activeSummaryOperation == nil, !meetingInProgress, !isTerminating else { return }
        let model = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        if WhisperModel.isInstalled(at: model.localURL) {
            updateModelDownloadButton()
            return
        }
        let operation = OperationControl()
        activeOperation = operation
        busyKind = .modelDownload
        isBusy = true
        setBusyControls(true)
        updateMeetingBadgeMenu()
        updateModelDownloadButton()
        spinner.startAnimation(nil)
        status.stringValue = "Downloading \(model.title.components(separatedBy: " · ").first ?? model.title)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.download(model.url, to: model.localURL, control: operation) { fraction in
                    let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                    DispatchQueue.main.async {
                        guard self.activeOperation === operation, !operation.isCancelled else { return }
                        self.status.stringValue = "Downloading \(model.id)…\(percent)"
                    }
                }
                try operation.check()
                DispatchQueue.main.async {
                    guard self.activeOperation === operation else { return }
                    self.status.stringValue = "\(model.title.components(separatedBy: " · ").first ?? model.title) is downloaded and ready."
                    self.finishBusy()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.activeOperation === operation else { return }
                    if operation.isCancelled || error as? AppError == .cancelled {
                        self.status.stringValue = "Model download cancelled. The incomplete download was removed."
                    } else {
                        self.status.stringValue = "Model download failed: \(error.localizedDescription)"
                    }
                    self.finishBusy()
                }
            }
        }
    }

    @objc private func speakerDetectionChanged() {
        if speakerToggle.state == .on {
            status.stringValue = "Speaker detection is enabled and runs locally."
        } else {
            status.stringValue = "Speaker detection is off. The transcript will contain words and timestamps only."
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let id = speakerFields.first(where: { $0.value === field })?.key else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            field.stringValue = speakerNames[id] ?? "Speaker \(id + 1)"
            return
        }
        speakerNames[id] = name
        refreshTranscriptAndExports()
    }

    private func updateSpeakerEditors() {
        for view in speakerEditors.arrangedSubviews {
            speakerEditors.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        speakerFields = [:]
        let ids = Array(Set(transcriptSegments.compactMap(\.speakerID))).sorted()
        speakerEditors.isHidden = ids.isEmpty
        transcriptTopConstraint?.isActive = false
        if ids.isEmpty {
            if let previewContainer {
                transcriptTopConstraint = transcript.enclosingScrollView?.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 28)
            }
        } else {
            let title = NSTextField(labelWithString: "Speakers")
            title.font = .systemFont(ofSize: 11, weight: .medium)
            title.textColor = .secondaryLabelColor
            speakerEditors.addArrangedSubview(title)
            for (position, id) in ids.enumerated() {
                let field = NSTextField(string: speakerNames[id] ?? "Speaker \(position + 1)")
                field.placeholderString = "Speaker \(position + 1)"
                field.font = .systemFont(ofSize: 11)
                field.delegate = self
                field.widthAnchor.constraint(equalToConstant: 132).isActive = true
                speakerFields[id] = field
                speakerNames[id] = field.stringValue
                speakerEditors.addArrangedSubview(field)
            }
            if let scroll = transcript.enclosingScrollView {
                transcriptTopConstraint = scroll.topAnchor.constraint(equalTo: speakerEditors.bottomAnchor, constant: 8)
            }
        }
        transcriptTopConstraint?.isActive = true
    }

    private func refreshTranscriptAndExports() {
        transcript.string = Self.renderTranscript(transcriptSegments, names: speakerNames)
        if let outputBase {
            do {
                try Self.writeExports(base: outputBase, segments: transcriptSegments, names: speakerNames)
                status.stringValue = "Speaker names updated in the transcript and TXT, SRT, and VTT exports."
            } catch {
                status.stringValue = "Name changed in preview; export update failed: \(error.localizedDescription)"
            }
        }
    }

    private func updateTranscriptActionButtons() {
        let hasTranscript = !transcriptSegments.isEmpty
        copyTranscriptButton.isEnabled = hasTranscript
        exportTranscriptButton.isEnabled = hasTranscript
    }

    @objc private func copyTranscript() {
        let text = Self.renderTranscript(transcriptSegments, names: speakerNames)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            status.stringValue = "Could not copy the transcript to the clipboard."
            return
        }
        status.stringValue = "Transcript copied to the clipboard."
    }

    @objc private func exportTranscript(_ sender: NSPopUpButton) {
        guard !transcriptSegments.isEmpty,
              let selectedTitle = sender.selectedItem?.title,
              let format = TranscriptExportFormat.allCases.first(where: { $0.menuTitle == selectedTitle }) else { return }

        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        let baseName = outputBase?.lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let contents = Self.exportContent(format: format, segments: transcriptSegments, names: speakerNames)
            try contents.write(to: destination, atomically: true, encoding: .utf8)
            status.stringValue = "Transcript exported as \(destination.lastPathComponent)."
        } catch {
            status.stringValue = "Transcript export failed: \(error.localizedDescription)"
        }
    }

    @objc private func showResults() {
        if let resultFolder { NSWorkspace.shared.open(resultFolder) }
    }

    @objc private func openMeetingRecordings() {
        if let meetingRecordingsFolder { NSWorkspace.shared.open(meetingRecordingsFolder) }
    }

    @objc private func openAppFromBadge() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func transcriptionButtonClicked() {
        if busyKind == .transcription, let operation = activeOperation {
            transcribeButton.title = "Canceling…"
            transcribeButton.isEnabled = false
            status.stringValue = "Cancelling transcription…"
            operation.cancel()
            return
        }
        startTranscription()
    }

    private func startTranscription() {
        guard let file = selectedFile, activeOperation == nil, !meetingInProgress, !isTerminating else { return }
        clearMeetingNotes()
        resultFolder = nil
        showResultsButton.isHidden = true
        let operation = OperationControl()
        activeOperation = operation
        busyKind = .transcription
        isBusy = true
        setBusyControls(true)
        updateMeetingBadgeMenu()
        transcribeButton.title = "Cancel"
        transcribeButton.isEnabled = true
        updateModelDownloadButton()
        spinner.startAnimation(nil)
        status.stringValue = "Preparing the local Whisper model…"
        transcript.string = "Starting transcription…\n\nText will appear here as Whisper completes each segment."
        transcript.textColor = .secondaryLabelColor
        transcriptSegments = []
        speakerNames = [:]
        outputBase = nil
        updateSpeakerEditors()
        updateTranscriptActionButtons()
        let model = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        let langIndex = languagePicker.indexOfSelectedItem
        let detectSpeakers = speakerToggle.state == .on
        let codes = ["auto", "en", "es", "fr", "de", "zh", "ja", "ko"]
        let customCode = customLanguage.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lang = model.id.hasSuffix(".en") ? "en" : (langIndex == 8 ? (customCode.isEmpty ? "auto" : customCode) : codes[max(0, min(langIndex, 7))])
        let reportProgress: (String) -> Void = { message in
            DispatchQueue.main.async {
                guard self.activeOperation === operation, !operation.isCancelled else { return }
                self.status.stringValue = message
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Self.transcribe(file: file, model: model, language: lang,
                                                 detectSpeakers: detectSpeakers, control: operation, progress: reportProgress,
                                                 liveTranscript: { segments in
                    DispatchQueue.main.async {
                        guard self.activeOperation === operation, !operation.isCancelled else { return }
                        self.transcriptSegments = segments
                        self.transcript.string = Self.renderTranscript(segments, names: [:])
                        self.transcript.textColor = .labelColor
                        self.transcript.scrollRangeToVisible(NSRange(location: self.transcript.string.utf16.count, length: 0))
                        self.updateTranscriptActionButtons()
                    }
                })
                DispatchQueue.main.async {
                    guard self.activeOperation === operation else { return }
                    self.transcriptSegments = result.segments
                    self.speakerNames = Dictionary(uniqueKeysWithValues: result.speakerIDs.enumerated().map { ($1, "Speaker \($0 + 1)") })
                    self.outputBase = result.base
                    self.updateSpeakerEditors()
                    self.transcript.string = Self.renderTranscript(result.segments, names: self.speakerNames)
                    self.transcript.textColor = .labelColor
                    self.updateTranscriptActionButtons()
                    self.resultFolder = result.folder
                    self.showResultsButton.isHidden = false
                    if let warning = result.speakerWarning {
                        self.status.stringValue = "Transcript saved, but speaker detection could not run: \(warning)"
                    } else if result.speakerIDs.isEmpty && detectSpeakers {
                        self.status.stringValue = "Transcription saved. No distinct speakers were confidently detected."
                    } else if detectSpeakers {
                        self.status.stringValue = "Done. Identified \(result.speakerIDs.count) speakers and saved TXT, SRT, and VTT."
                    } else {
                        self.status.stringValue = "Done. Saved TXT, SRT, and VTT next to the source file."
                    }
                    self.finish()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.activeOperation === operation else { return }
                    if operation.isCancelled || error as? AppError == .cancelled {
                        self.status.stringValue = "Transcription cancelled. Any text already shown remains in the preview; exports were not updated."
                    } else {
                        self.status.stringValue = "Transcription failed: \(error.localizedDescription)"
                    }
                    self.finish()
                }
            }
        }
    }

    private func setBusyControls(_ busy: Bool) {
        let blocked = busy || meetingInProgress || isTerminating
        chooseButton.isEnabled = !blocked
        modelPicker.isEnabled = !blocked
        let model = WhisperModel.choices[min(max(0, modelPicker.indexOfSelectedItem), WhisperModel.choices.count - 1)]
        languagePicker.isEnabled = !blocked && !model.id.hasSuffix(".en")
        customLanguage.isEnabled = !blocked
        speakerToggle.isEnabled = !blocked
        transcribeButton.isEnabled = busyKind == .transcription
            ? activeOperation?.isCancelled == false : !blocked && selectedFile != nil
        downloadModelButton.isEnabled = !blocked
        if activeSummaryOperation == nil { summaryButton.isEnabled = meetingResult != nil && !blocked }
    }

    private func finish() {
        finishBusy()
    }

    private func finishBusy() {
        isBusy = false
        activeOperation = nil
        busyKind = nil
        transcribeButton.title = "Transcribe"
        setBusyControls(false)
        modelChanged()
        spinner.stopAnimation(nil)
        updateMeetingBadgeMenu()
        if waitingForOperationBeforeQuit {
            waitingForOperationBeforeQuit = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func groupBox(_ title: String, content: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        box.contentViewMargins = NSSize(width: 12, height: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.autoresizingMask = [.width, .height]
        box.contentView = content
        return box
    }

    static func transcribe(file: URL, model: WhisperModel, language: String, detectSpeakers: Bool,
                                   control: OperationControl,
                                   progress: @escaping (String) -> Void,
                                   liveTranscript: @escaping ([TranscriptSegment]) -> Void) throws ->
        (folder: URL, base: URL, segments: [TranscriptSegment], speakerIDs: [Int], speakerWarning: String?) {
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli"),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw AppError.message("The bundled Whisper engine is missing. Rebuild the app with ./build-app.sh.")
        }
        let support = model.localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let modelURL = model.localURL
        if !WhisperModel.isInstalled(at: modelURL) {
            progress("Downloading \(model.title.components(separatedBy: " · ").first ?? model.title) (about \(model.downloadSize)); first download may take a while…")
            try download(model.url, to: modelURL, control: control) { fraction in
                let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                progress("Downloading \(model.id)…\(percent)")
            }
        }
        try control.check()

        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError.message("FFmpeg is needed for broad media-format support. Install it with Homebrew: brew install ffmpeg")
        }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        progress("Converting audio from \(file.lastPathComponent)…")
        _ = try run(ffmpeg, ["-y", "-i", file.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path], control: control)
        let base = file.deletingPathExtension()
        progress("Transcribing with \(model.id). Longer recordings may take several minutes…")
        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        let vadURL = support.appendingPathComponent(WhisperModel.vadFile)
        if !WhisperModel.isInstalled(at: vadURL) {
            progress("Downloading small voice activity model to skip silence…")
            try download(WhisperModel.vadURL, to: vadURL, control: control) { _ in }
        }
        try control.check()
        var liveSegments: [TranscriptSegment] = []
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            [".txt", ".srt", ".vtt"].forEach { suffix in
                try? FileManager.default.removeItem(atPath: tempBase.path + suffix)
            }
        }
        _ = try run(cli.path, ["-t", String(threads), "-mc", "0", "-m", modelURL.path, "-f", wav.path, "-l", language,
                           "-vm", vadURL.path, "--vad", "-sns", "-of", tempBase.path, "-otxt", "-osrt", "-ovtt", "-np"],
                    control: control,
                    onTranscriptSegment: { segment in
            liveSegments.append(segment)
            liveTranscript(liveSegments)
        })
        try control.check()
        let srtURL = URL(fileURLWithPath: tempBase.path + ".srt")
        guard let srt = try? String(contentsOf: srtURL, encoding: .utf8) else {
            throw AppError.message("Whisper finished, but its timestamped transcript could not be read.")
        }
        var segments = parseSRT(srt)
        var speakerIDs: [Int] = []
        var speakerWarning: String?
        if detectSpeakers {
            do {
                let diarizer = Bundle.main.resourceURL?.appendingPathComponent("sherpa-onnx-offline-speaker-diarization")
                guard let diarizer, FileManager.default.isExecutableFile(atPath: diarizer.path) else {
                    throw AppError.message("The speaker detection engine is missing. Rebuild the app with ./build-app.sh.")
                }
                let segmentationDir = support.deletingLastPathComponent().appendingPathComponent("speaker-models/sherpa-onnx-pyannote-segmentation-3-0", isDirectory: true)
                let segmentation = segmentationDir.appendingPathComponent("model.onnx")
                let embedding = support.deletingLastPathComponent().appendingPathComponent("speaker-models/wespeaker_en_voxceleb_resnet34.onnx")
                if !FileManager.default.fileExists(atPath: segmentation.path) {
                    progress("Downloading local speaker segmentation model (about 6 MB)…")
                    let archive = support.deletingLastPathComponent().appendingPathComponent("speaker-segmentation.tar.bz2")
                    try download(URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!, to: archive, control: control) { _ in }
                    try FileManager.default.createDirectory(at: segmentationDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                    _ = try run("/usr/bin/tar", ["-xjf", archive.path, "-C", segmentationDir.deletingLastPathComponent().path], control: control)
                    try? FileManager.default.removeItem(at: archive)
                }
                if !FileManager.default.fileExists(atPath: embedding.path) {
                    progress("Downloading English speaker recognition model (about 25 MB)…")
                    try download(URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx")!, to: embedding, control: control) { _ in }
                }
                try control.check()
                progress("Identifying speakers locally… 0%")
                let diarization = try run(diarizer.path, ["--clustering.cluster-threshold=0.95",
                                                           "--segmentation.num-threads=4", "--embedding.num-threads=2",
                                                           "--segmentation.pyannote-model=\(segmentation.path)",
                                                           "--embedding.model=\(embedding.path)", wav.path], control: control,
                                          progress: { progress("Identifying speakers locally… \($0)") })
                let turns = parseDiarization(diarization)
                for index in segments.indices {
                    var overlapBySpeaker: [Int: Double] = [:]
                    for turn in turns {
                        let overlap = max(0, min(segments[index].end, turn.end) - max(segments[index].start, turn.start))
                        if let speakerID = turn.speakerID, overlap > 0 {
                            overlapBySpeaker[speakerID, default: 0] += overlap
                        }
                    }
                    segments[index].speakerID = overlapBySpeaker.max(by: { $0.value < $1.value })?.key
                }
                speakerIDs = Array(Set(segments.compactMap(\.speakerID))).sorted()
            } catch {
                if control.isCancelled || error as? AppError == .cancelled { throw AppError.cancelled }
                speakerWarning = error.localizedDescription
            }
        }
        try control.check()
        let defaultNames = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map { ($1, "Speaker \($0 + 1)") })
        try writeExports(base: base, segments: segments, names: defaultNames, control: control)
        return (file.deletingLastPathComponent(), base, segments, speakerIDs, speakerWarning)
    }

    static func parseSRT(_ source: String) -> [TranscriptSegment] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let separators = try? NSRegularExpression(pattern: #"\n[\t ]*\n"#)
        let blocks = (separators?.stringByReplacingMatches(in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized), withTemplate: "\n\n") ?? normalized)
            .components(separatedBy: "\n\n")
        var result: [TranscriptSegment] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeLine = lines.first(where: { $0.contains("-->") }),
                  let arrow = timeLine.range(of: "-->") else { continue }
            let start = parseTimestamp(String(timeLine[..<arrow.lowerBound]))
            let end = parseTimestamp(String(timeLine[arrow.upperBound...]))
            let textStart = (lines.firstIndex(of: timeLine) ?? 0) + 1
            let text = lines.dropFirst(textStart).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, let end, end >= start, !text.isEmpty {
                result.append(TranscriptSegment(start: start, end: end, text: text, speakerID: nil))
            }
        }
        return result
    }

    static func parseDiarization(_ source: String) -> [TranscriptSegment] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*(\d+(?:\.\d+)?)\s+--\s+(\d+(?:\.\d+)?)\s+speaker_(\d+)"#) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges == 4,
                  let start = Double(ns.substring(with: match.range(at: 1))),
                  let end = Double(ns.substring(with: match.range(at: 2))),
                  let id = Int(ns.substring(with: match.range(at: 3))),
                  start.isFinite, end.isFinite, end >= start else { return nil }
            return TranscriptSegment(start: start, end: end, text: "", speakerID: id)
        }
    }

    static func parseTimestamp(_ value: String) -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let fields = normalized.split(separator: ":", omittingEmptySubsequences: false)
        func digits(_ field: Substring) -> Bool { !field.isEmpty && field.allSatisfy { $0.isASCII && $0.isNumber } }
        guard fields.count == 3, digits(fields[0]), digits(fields[1]) else { return nil }
        let secondFields = fields[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondFields.count), secondFields.allSatisfy(digits),
              secondFields.count == 1 || secondFields[1].count <= 3,
              let hours = Double(fields[0]), let minutes = Double(fields[1]), let seconds = Double(fields[2]),
              hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        let timestamp = hours * 3600 + minutes * 60 + seconds
        return timestamp.isFinite ? timestamp : nil
    }

    static func timeString(_ seconds: Double, separator: String) -> String {
        let safeSeconds = seconds.isFinite ? min(max(0, seconds), Double(Int.max / 2) / 1000) : 0
        let milliseconds = Int((safeSeconds * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1000) % 60
        let ms = milliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, ms)
    }

    static func renderTranscript(_ segments: [TranscriptSegment], names: [Int: String]) -> String {
        segments.map { segment in
            let speaker = segment.speakerID.flatMap { names[$0] }
            let label = speaker.map { "  \($0):" } ?? ""
            return "[\(timeString(segment.start, separator: ".").prefix(8))]\(label)  \(segment.text)"
        }.joined(separator: "\n\n")
    }

    static func writeExports(base: URL, segments: [TranscriptSegment], names: [Int: String],
                             control: OperationControl? = nil) throws {
        try control?.check()
        let files = FileManager.default
        let staging = base.deletingLastPathComponent().appendingPathComponent(".exports-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        var preserveBackups = false
        defer { if !preserveBackups { try? files.removeItem(at: staging) } }
        let formats = TranscriptExportFormat.allCases
        for format in formats {
            try exportContent(format: format, segments: segments, names: names)
                .write(to: staging.appendingPathComponent(format.fileExtension), atomically: true, encoding: .utf8)
        }
        let commitExports = {
            var committed: [URL] = []
            var backups: [(destination: URL, backup: URL)] = []
            do {
                for format in formats {
                    let destination = URL(fileURLWithPath: base.path + "." + format.fileExtension)
                    if files.fileExists(atPath: destination.path) {
                        let attributes = try files.attributesOfItem(atPath: destination.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular else {
                            throw AppError.message("Cannot replace \(destination.lastPathComponent): it is not a regular file.")
                        }
                        let backup = staging.appendingPathComponent(format.fileExtension + ".previous")
                        try files.moveItem(at: destination, to: backup)
                        backups.append((destination, backup))
                    }
                    try files.moveItem(at: staging.appendingPathComponent(format.fileExtension), to: destination)
                    committed.append(destination)
                }
            } catch {
                do {
                    for destination in committed.reversed() { try files.removeItem(at: destination) }
                    for entry in backups.reversed() { try files.moveItem(at: entry.backup, to: entry.destination) }
                } catch let restoreError {
                    preserveBackups = true
                    throw AppError.message("Export failed and previous files could not all be restored. Backups remain at \(staging.path): \(restoreError.localizedDescription)")
                }
                throw error
            }
        }
        if let control { try control.commit(commitExports) } else { try commitExports() }
    }

    private static func exportContent(format: TranscriptExportFormat, segments: [TranscriptSegment],
                                      names: [Int: String]) -> String {
        switch format {
        case .plainText:
            return segments.map { segment in
                let speaker = segment.speakerID.flatMap { names[$0] }
                let label = speaker.map { "\($0): " } ?? ""
                return "[\(timeString(segment.start, separator: "."))] \(label)\(segment.text)"
            }.joined(separator: "\n\n")
        case .srt:
            return segments.enumerated().map { index, segment in
                let speaker = segment.speakerID.flatMap { names[$0] }
                let text = (speaker.map { "\($0): " } ?? "") + segment.text
                return "\(index + 1)\n\(timeString(segment.start, separator: ",")) --> \(timeString(segment.end, separator: ","))\n\(text)"
            }.joined(separator: "\n\n") + "\n"
        case .vtt:
            return "WEBVTT\n\n" + segments.enumerated().map { index, segment in
                let speaker = segment.speakerID.flatMap { names[$0] }
                let text = ((speaker.map { "\($0): " } ?? "") + segment.text)
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "\(index + 1)\n\(timeString(segment.start, separator: ".")) --> \(timeString(segment.end, separator: "."))\n\(text)"
            }.joined(separator: "\n\n") + "\n"
        }
    }

    static func download(_ source: URL, to destination: URL, control: OperationControl,
                                progress: (Double?) -> Void) throws {
        try control.check()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: staging) }
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?
        var stagedDownloadReady = false
        let task = URLSession.shared.downloadTask(with: source) { temp, response, error in
            defer { semaphore.signal() }
            if let error { downloadError = error; return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let temp else {
                downloadError = AppError.message("Could not download the required model.")
                return
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: temp.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw AppError.message("The downloaded model is empty.") }
                if response.expectedContentLength > 0, response.value(forHTTPHeaderField: "Content-Encoding") == nil,
                   size != response.expectedContentLength {
                    throw AppError.message("The downloaded model is incomplete.")
                }
                switch destination.pathExtension.lowercased() {
                case "bin":
                    guard WhisperModel.isInstalled(at: temp) else { throw AppError.message("The downloaded Whisper model is invalid.") }
                case "gguf":
                    let file = try FileHandle(forReadingFrom: temp)
                    defer { try? file.close() }
                    guard try file.read(upToCount: 4) == Data("GGUF".utf8), size > 8 else {
                        throw AppError.message("The downloaded notes model is invalid.")
                    }
                default: break
                }
                try FileManager.default.moveItem(at: temp, to: staging)
                stagedDownloadReady = true
            } catch {
                downloadError = error
            }
        }
        control.attach(task)
        task.resume()
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            let fraction = task.progress.isIndeterminate ? nil : task.progress.fractionCompleted
            progress(fraction)
        }
        control.detach(task)
        try control.check()
        if let downloadError { throw downloadError }
        guard stagedDownloadReady else { throw AppError.message("Model download failed.") }
        try control.commit {
            if FileManager.default.fileExists(atPath: destination.path) {
                if destination.pathExtension.lowercased() == "bin", !WhisperModel.isInstalled(at: destination) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else {
                        throw AppError.message("The model location is not a regular file: \(destination.path)")
                    }
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                }
                return
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    static func run(_ executable: String, _ arguments: [String],
                            control: OperationControl? = nil,
                            progress: ((String) -> Void)? = nil,
                            onTranscriptSegment: ((TranscriptSegment) -> Void)? = nil) throws -> String {
        try control?.check()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppError.message("Could not create the transcription log.")
        }
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        var capturedOutput = Data()
        var pendingLine = Data()
        func consumeLine(_ line: String) {
            if line.contains("progress "),
               let marker = line.range(of: "progress ", options: .backwards),
               let value = Double(line[marker.upperBound...].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
               value.isFinite {
                progress?("\(Int(min(100, max(0, value)).rounded()))%")
            }
            guard let onTranscriptSegment,
                  let open = line.firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]"),
                  let arrow = line[open..<close].range(of: " --> ") else { return }
            let startText = String(line[line.index(after: open)..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let endText = String(line[arrow.upperBound..<close]).trimmingCharacters(in: .whitespaces)
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = parseTimestamp(startText), let end = parseTimestamp(endText), end >= start, !text.isEmpty else { return }
            onTranscriptSegment(TranscriptSegment(start: start, end: end, text: text, speakerID: nil))
        }
        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            capturedOutput.append(data)
            pendingLine.append(data)
            while let newline = pendingLine.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                consumeLine(String(decoding: pendingLine[..<newline], as: UTF8.self))
                pendingLine.removeSubrange(...newline)
            }
        }
        try process.run()
        control?.attach(process)
        defer { control?.detach(process) }
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.25)
            while true {
                let data = reader.readData(ofLength: 65_536)
                if data.isEmpty { break }
                consume(data)
            }
        }
        process.waitUntilExit()
        while true {
            let data = reader.readData(ofLength: 65_536)
            if data.isEmpty { break }
            consume(data)
        }
        if !pendingLine.isEmpty { consumeLine(String(decoding: pendingLine, as: UTF8.self)) }
        try? log.synchronize()
        let output = String(decoding: capturedOutput, as: UTF8.self)
        try control?.check()
        guard process.terminationStatus == 0 else {
            throw AppError.message(output.isEmpty ? "A media conversion or transcription command failed." : String(output.suffix(900)))
        }
        return output
    }
}

enum AppError: LocalizedError, Equatable {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return "Operation cancelled."
        }
    }
}
