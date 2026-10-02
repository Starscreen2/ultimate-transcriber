import AppKit
import UniformTypeIdentifiers

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
}

private struct TranscriptSegment {
    var start: Double
    var end: Double
    var text: String
    var speakerID: Int?
}

private final class OperationControl {
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

    func cancel() {
        lock.lock()
        cancelled = true
        let activeProcess = process
        let activeDownload = downloadTask
        lock.unlock()
        activeDownload?.cancel()
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
    }

    func attach(_ process: Process) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel { self.process = process }
        lock.unlock()
        if shouldCancel && process.isRunning { process.terminate() }
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
    private let spinner = NSProgressIndicator()
    private let transcribeButton = NSButton(title: "Transcribe", target: nil, action: nil)
    private let showResultsButton = NSButton(title: "Show Results", target: nil, action: nil)
    private let speakerToggle = NSButton(checkboxWithTitle: "Detect speakers", target: nil, action: nil)
    private let speakerEditors = NSStackView()
    private var selectedFile: URL?
    private var resultFolder: URL?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
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
        downloadModelButton.target = self
        downloadModelButton.action = #selector(downloadSelectedModel)
        downloadModelButton.bezelStyle = .rounded
        downloadModelButton.controlSize = .small
        showResultsButton.target = self
        showResultsButton.action = #selector(showResults)
        showResultsButton.isHidden = true
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
         downloadModelButton, speakerEditors, previewBox, transcriptScroll, speakerNote, footer].forEach { root.addSubview($0) }

        [heading, subheading, inputBox, fileCaption, filename, filePath, chooseButton,
         divider, modelCaption, modelPicker, modelDetail, languageCaption, languagePicker,
         customLanguage, speakerToggle, transcribeButton, spinner, showResultsButton, statusRow,
         downloadModelButton, speakerEditors,
         statusIcon, status, previewBox, transcriptScroll, speakerNote, footer].forEach {
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
            status.rightAnchor.constraint(equalTo: statusRow.rightAnchor),
            status.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),

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
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        if panel.runModal() == .OK, let url = panel.url {
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
            languagePicker.isEnabled = false
            modelDetail.stringValue += " Language is set to English for this model."
        } else {
            languagePicker.isEnabled = true
        }
        updateModelDownloadButton()
    }

    private func updateModelDownloadButton() {
        let selected = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        if busyKind == .modelDownload {
            downloadModelButton.title = "Cancel Download"
            downloadModelButton.isEnabled = true
        } else if FileManager.default.fileExists(atPath: selected.localURL.path) {
            downloadModelButton.title = "Model Downloaded"
            downloadModelButton.isEnabled = false
        } else {
            downloadModelButton.title = "Download Model (\(selected.downloadSize))"
            downloadModelButton.isEnabled = activeOperation == nil
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
        guard activeOperation == nil else { return }
        let model = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        if FileManager.default.fileExists(atPath: model.localURL.path) {
            updateModelDownloadButton()
            return
        }
        let operation = OperationControl()
        activeOperation = operation
        busyKind = .modelDownload
        isBusy = true
        setBusyControls(true)
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

    @objc private func showResults() {
        if let resultFolder { NSWorkspace.shared.open(resultFolder) }
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
        guard let file = selectedFile, activeOperation == nil else { return }
        let operation = OperationControl()
        activeOperation = operation
        busyKind = .transcription
        isBusy = true
        setBusyControls(true)
        transcribeButton.title = "Cancel"
        transcribeButton.isEnabled = true
        updateModelDownloadButton()
        spinner.startAnimation(nil)
        status.stringValue = "Preparing the local Whisper model…"
        transcript.string = "Starting transcription…\n\nText will appear here as Whisper completes each segment."
        transcript.textColor = .secondaryLabelColor
        let model = WhisperModel.choices[min(max(modelPicker.indexOfSelectedItem, 0), WhisperModel.choices.count - 1)]
        let langIndex = languagePicker.indexOfSelectedItem
        let detectSpeakers = speakerToggle.state == .on
        let codes = ["auto", "en", "es", "fr", "de", "zh", "ja", "ko"]
        let lang = model.id.hasSuffix(".en") ? "en" : (langIndex == 8 ? (customLanguage.stringValue.isEmpty ? "auto" : customLanguage.stringValue) : codes[max(0, min(langIndex, 7))])
        let reportProgress: (String) -> Void = { message in
            DispatchQueue.main.async { self.status.stringValue = message }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Self.transcribe(file: file, model: model, language: lang,
                                                 detectSpeakers: detectSpeakers, control: operation, progress: reportProgress,
                                                 liveTranscript: { segments in
                    DispatchQueue.main.async {
                        self.transcriptSegments = segments
                        self.transcript.string = Self.renderTranscript(segments, names: [:])
                        self.transcript.textColor = .labelColor
                        self.transcript.scrollRangeToVisible(NSRange(location: self.transcript.string.utf16.count, length: 0))
                    }
                })
                DispatchQueue.main.async {
                    self.transcriptSegments = result.segments
                    self.speakerNames = Dictionary(uniqueKeysWithValues: result.speakerIDs.enumerated().map { ($1, "Speaker \($0 + 1)") })
                    self.outputBase = result.base
                    self.updateSpeakerEditors()
                    self.transcript.string = Self.renderTranscript(result.segments, names: self.speakerNames)
                    self.transcript.textColor = .labelColor
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
        chooseButton.isEnabled = !busy
        modelPicker.isEnabled = !busy
        languagePicker.isEnabled = !busy
        customLanguage.isEnabled = !busy
        speakerToggle.isEnabled = !busy
        transcribeButton.isEnabled = !busy && selectedFile != nil
        downloadModelButton.isEnabled = !busy
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

    private static func transcribe(file: URL, model: WhisperModel, language: String, detectSpeakers: Bool,
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
        if !FileManager.default.fileExists(atPath: modelURL.path) {
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
        if !FileManager.default.fileExists(atPath: vadURL.path) {
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
        try writeExports(base: base, segments: segments, names: defaultNames)
        return (file.deletingLastPathComponent(), base, segments, speakerIDs, speakerWarning)
    }

    private static func parseSRT(_ source: String) -> [TranscriptSegment] {
        let blocks = source.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
        var result: [TranscriptSegment] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timeLine = lines.first(where: { $0.contains(" --> ") }),
                  let arrow = timeLine.range(of: " --> ") else { continue }
            let start = parseTimestamp(String(timeLine[..<arrow.lowerBound]))
            let end = parseTimestamp(String(timeLine[arrow.upperBound...]))
            let textStart = (lines.firstIndex(of: timeLine) ?? 0) + 1
            let text = lines.dropFirst(textStart).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let start, let end, !text.isEmpty { result.append(TranscriptSegment(start: start, end: end, text: text, speakerID: nil)) }
        }
        return result
    }

    private static func parseDiarization(_ source: String) -> [TranscriptSegment] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\s*(\d+(?:\.\d+)?)\s+--\s+(\d+(?:\.\d+)?)\s+speaker_(\d+)"#) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges == 4,
                  let start = Double(ns.substring(with: match.range(at: 1))),
                  let end = Double(ns.substring(with: match.range(at: 2))),
                  let id = Int(ns.substring(with: match.range(at: 3))) else { return nil }
            return TranscriptSegment(start: start, end: end, text: "", speakerID: id)
        }
    }

    private static func parseTimestamp(_ value: String) -> Double? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":").compactMap { Double($0) }
        guard pieces.count == 3 else { return nil }
        return pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
    }

    private static func timeString(_ seconds: Double, separator: String) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1000) % 60
        let ms = milliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, ms)
    }

    private static func renderTranscript(_ segments: [TranscriptSegment], names: [Int: String]) -> String {
        segments.map { segment in
            let speaker = segment.speakerID.flatMap { names[$0] }
            let label = speaker.map { "  \($0):" } ?? ""
            return "[\(timeString(segment.start, separator: ".").prefix(8))]\(label)  \(segment.text)"
        }.joined(separator: "\n\n")
    }

    private static func writeExports(base: URL, segments: [TranscriptSegment], names: [Int: String]) throws {
        let txt = segments.map { segment in
            let speaker = segment.speakerID.flatMap { names[$0] }
            let label = speaker.map { "\($0): " } ?? ""
            return "[\(timeString(segment.start, separator: "."))] \(label)\(segment.text)"
        }.joined(separator: "\n\n")
        let srt = segments.enumerated().map { index, segment in
            let speaker = segment.speakerID.flatMap { names[$0] }
            let text = (speaker.map { "\($0): " } ?? "") + segment.text
            return "\(index + 1)\n\(timeString(segment.start, separator: ",")) --> \(timeString(segment.end, separator: ","))\n\(text)"
        }.joined(separator: "\n\n") + "\n"
        let vtt = "WEBVTT\n\n" + segments.enumerated().map { index, segment in
            let speaker = segment.speakerID.flatMap { names[$0] }
            let text = (speaker.map { "\($0): " } ?? "") + segment.text
            return "\(index + 1)\n\(timeString(segment.start, separator: ".")) --> \(timeString(segment.end, separator: "."))\n\(text)"
        }.joined(separator: "\n\n") + "\n"
        try txt.write(to: URL(fileURLWithPath: base.path + ".txt"), atomically: true, encoding: .utf8)
        try srt.write(to: URL(fileURLWithPath: base.path + ".srt"), atomically: true, encoding: .utf8)
        try vtt.write(to: URL(fileURLWithPath: base.path + ".vtt"), atomically: true, encoding: .utf8)
    }

    private static func download(_ source: URL, to destination: URL, control: OperationControl,
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
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let temp else {
                downloadError = AppError.message("Could not download the required model.")
                return
            }
            do {
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
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private static func run(_ executable: String, _ arguments: [String],
                            control: OperationControl? = nil,
                            progress: ((String) -> Void)? = nil,
                            onTranscriptSegment: ((TranscriptSegment) -> Void)? = nil) throws -> String {
        try control?.check()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        defer { try? log.close(); try? FileManager.default.removeItem(at: logURL) }
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        var capturedOutput = ""
        var pendingLine = ""
        func consumeLine(_ line: String) {
            if line.contains("progress "),
               let marker = line.range(of: "progress ", options: .backwards),
               let value = Double(line[marker.upperBound...].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
                progress?("\(Int(value.rounded()))%")
            }
            guard let onTranscriptSegment,
                  let open = line.firstIndex(of: "["),
                  let close = line[open...].firstIndex(of: "]"),
                  let arrow = line[open..<close].range(of: " --> ") else { return }
            let startText = String(line[line.index(after: open)..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let endText = String(line[arrow.upperBound..<close]).trimmingCharacters(in: .whitespaces)
            let text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = parseTimestamp(startText), let end = parseTimestamp(endText), !text.isEmpty else { return }
            onTranscriptSegment(TranscriptSegment(start: start, end: end, text: text, speakerID: nil))
        }
        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            capturedOutput += chunk
            pendingLine += chunk
            let lines = pendingLine.components(separatedBy: .newlines)
            pendingLine = lines.last ?? ""
            for line in lines.dropLast() { consumeLine(line) }
        }
        try process.run()
        control?.attach(process)
        defer { control?.detach(process) }
        while process.isRunning {
            if control?.isCancelled == true && process.isRunning { process.terminate() }
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
        if !pendingLine.isEmpty { consumeLine(pendingLine) }
        try? log.synchronize()
        let output = capturedOutput
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
