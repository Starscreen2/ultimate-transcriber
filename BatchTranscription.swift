import AppKit
import Foundation
import UniformTypeIdentifiers

enum BatchTranscriptionState: String {
    case ready = "Ready"
    case queued = "Queued"
    case running = "Transcribing"
    case paused = "Paused"
    case completed = "Finished"
    case failed = "Failed"
    case cancelled = "Canceled"

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .ready, .queued, .running, .paused: return false
        }
    }
}

struct BatchTranscriptionItem: Identifiable {
    let id: UUID
    let sourceURL: URL
    let outputBaseURL: URL
    var state: BatchTranscriptionState
    var detail: String

    init(id: UUID = UUID(), sourceURL: URL, outputBaseURL: URL? = nil,
         state: BatchTranscriptionState = .ready, detail: String = "") {
        self.id = id
        self.sourceURL = sourceURL
        self.outputBaseURL = outputBaseURL ?? sourceURL.deletingPathExtension()
        self.state = state
        self.detail = detail
    }
}

struct BatchTranscriptionSettings {
    let model: WhisperModel
    let language: String
    let detectSpeakers: Bool

    var modelDisplayName: String {
        model.title.components(separatedBy: " · ").first ?? model.title
    }

    var languageDisplayName: String {
        switch language.lowercased() {
        case "auto": return "Auto Detect"
        case "en": return "English"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "zh": return "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        default: return language.uppercased()
        }
    }

    var speakerDisplayName: String { detectSpeakers ? "On" : "Off" }
}

struct BatchTranscriptionResult {
    let folder: URL
    let base: URL
    let segments: [TranscriptSegment]
    let speakerIDs: [Int]
    let speakerWarning: String?
}

enum BatchTranscriptionPlan {
    static func makeItems(for files: [URL]) -> [BatchTranscriptionItem] {
        var seen = Set<String>()
        let uniqueFiles = files.filter { file in
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return false
            }
            return seen.insert(fileIdentity(file)).inserted
        }

        let grouped = Dictionary(grouping: uniqueFiles.indices) { outputBase(for: uniqueFiles[$0]).path }
        var usedOutputBases = Set<String>()
        return uniqueFiles.enumerated().map { index, file in
            let defaultBase = outputBase(for: file)
            var candidate = defaultBase
            if (grouped[defaultBase.path]?.count ?? 0) > 1 {
                let extensionName = file.pathExtension.isEmpty ? "file" : file.pathExtension
                candidate = defaultBase.deletingLastPathComponent()
                    .appendingPathComponent("\(defaultBase.lastPathComponent) (\(extensionName))")
            }

            let originalCandidate = candidate
            var suffix = 2
            while !usedOutputBases.insert(outputIdentity(candidate)).inserted {
                candidate = originalCandidate.deletingLastPathComponent()
                    .appendingPathComponent("\(originalCandidate.lastPathComponent) (\(suffix))")
                suffix += 1
            }
            return BatchTranscriptionItem(sourceURL: file, outputBaseURL: candidate)
        }
    }

    static func summary(for items: [BatchTranscriptionItem]) -> String {
        guard !items.isEmpty else { return "No files selected." }
        let completed = items.filter { $0.state == .completed }.count
        let failed = items.filter { $0.state == .failed }.count
        let cancelled = items.filter { $0.state == .cancelled }.count
        let running = items.filter { $0.state == .running }.count
        let paused = items.filter { $0.state == .paused }.count
        let queued = items.filter { $0.state == .queued }.count
        let ready = items.filter { $0.state == .ready }.count
        if ready == items.count { return "\(items.count) file\(items.count == 1 ? "" : "s") ready." }
        var parts = ["\(completed) finished", "\(failed) failed", "\(cancelled) canceled"]
        if running > 0 { parts.append("\(running) running") }
        if paused > 0 { parts.append("\(paused) paused") }
        if queued > 0 { parts.append("\(queued) queued") }
        if ready > 0 { parts.append("\(ready) ready") }
        return "\(items.count) files · " + parts.joined(separator: " · ")
    }

    private static func outputBase(for file: URL) -> URL {
        file.deletingPathExtension().standardizedFileURL
    }

    private static func fileIdentity(_ file: URL) -> String {
        file.standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func outputIdentity(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

private final class BatchFileCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    private func buildView() {
        iconView.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Media file")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconView, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            iconView.widthAnchor.constraint(equalToConstant: 25),
            iconView.heightAnchor.constraint(equalToConstant: 25)
        ])
    }

    func configure(with item: BatchTranscriptionItem) {
        nameLabel.stringValue = item.sourceURL.lastPathComponent
        nameLabel.toolTip = item.sourceURL.path
        let fileType = item.sourceURL.pathExtension.uppercased()
        let renamedOutput = item.outputBaseURL.lastPathComponent != item.sourceURL.deletingPathExtension().lastPathComponent
        let outputNote = renamedOutput ? " · exports as \(item.outputBaseURL.lastPathComponent)" : ""
        detailLabel.stringValue = (fileType.isEmpty ? "Media file" : fileType) + outputNote
        detailLabel.toolTip = item.sourceURL.path
    }
}

private final class BatchStatusCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    private func buildView() {
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [stateLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [iconView, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            iconView.widthAnchor.constraint(equalToConstant: 19),
            iconView.heightAnchor.constraint(equalToConstant: 19)
        ])
    }

    func configure(with item: BatchTranscriptionItem) {
        let symbol: String
        let color: NSColor
        switch item.state {
        case .ready: symbol = "circle.dashed"; color = .secondaryLabelColor
        case .queued: symbol = "clock"; color = .secondaryLabelColor
        case .running: symbol = "waveform.circle.fill"; color = .controlAccentColor
        case .paused: symbol = "pause.circle"; color = .systemOrange
        case .completed: symbol = "checkmark.circle.fill"; color = .systemGreen
        case .failed: symbol = "exclamationmark.circle.fill"; color = .systemRed
        case .cancelled: symbol = "xmark.circle"; color = .secondaryLabelColor
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.state.rawValue)
        iconView.contentTintColor = color
        stateLabel.stringValue = item.state == .completed ? "Completed" : item.state.rawValue
        stateLabel.textColor = item.state == .failed ? .systemRed : .labelColor
        detailLabel.stringValue = item.detail.isEmpty ? defaultDetail(for: item.state) : item.detail
        detailLabel.toolTip = detailLabel.stringValue
    }

    private func defaultDetail(for state: BatchTranscriptionState) -> String {
        switch state {
        case .ready: return "Ready to start"
        case .queued: return "Waiting for the next file"
        case .running: return "Working locally…"
        case .paused: return "Waiting to resume"
        case .completed: return "Exports saved"
        case .failed: return "Could not transcribe this file"
        case .cancelled: return "Canceled"
        }
    }
}

private final class BatchProgressCellView: NSTableCellView {
    private let bar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildView()
    }

    private func buildView() {
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.isDisplayedWhenStopped = false
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [bar, detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 8),
            detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    func configure(with state: BatchTranscriptionState) {
        bar.stopAnimation(nil)
        bar.isHidden = true
        bar.isIndeterminate = false
        bar.doubleValue = 0
        switch state {
        case .running:
            bar.isHidden = false
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            detailLabel.stringValue = "In progress"
        case .completed:
            bar.isHidden = false
            bar.doubleValue = 100
            detailLabel.stringValue = "Complete"
        case .paused:
            detailLabel.stringValue = "Paused"
        case .queued:
            detailLabel.stringValue = "Waiting"
        case .ready:
            detailLabel.stringValue = "Ready"
        case .failed:
            bar.isHidden = true
            detailLabel.stringValue = "Failed"
        case .cancelled:
            bar.isHidden = true
            detailLabel.stringValue = "Canceled"
        }
    }
}

final class BatchTranscriptionPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAddFiles: (([URL]) -> Void)?
    var onRemoveFiles: (([UUID]) -> Void)?
    var onStart: (() -> Void)?
    var onCancelCurrent: (() -> Void)?
    var onCancelRemaining: (() -> Void)?
    var onRetryFailed: (() -> Void)?
    var onOpenOutput: ((UUID) -> Void)?
    var onSelectResult: ((UUID) -> Void)?
    var onNewBatch: (() -> Void)?

    private var items: [BatchTranscriptionItem] = []
    private var activeItemID: UUID?
    private var hasStarted = false
    private var windowHasBeenCentered = false
    private var settings: BatchTranscriptionSettings?
    private let summaryLabel = NSTextField(wrappingLabelWithString: "No files selected.")
    private let table = NSTableView()
    private let heading = NSTextField(labelWithString: "Batch Transcription")
    private let subheading = NSTextField(labelWithString: "Uses the current settings from the main window for every file.")
    private let modelValue = NSTextField(labelWithString: "—")
    private let languageValue = NSTextField(labelWithString: "—")
    private let speakerValue = NSTextField(labelWithString: "—")
    private let emptyState = NSTextField(wrappingLabelWithString: "Add audio or video files to get started.")
    private let addButton = NSButton(title: "Add Files…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let startButton = NSButton(title: "Start Batch", target: nil, action: nil)
    private let cancelCurrentButton = NSButton(title: "Cancel Current", target: nil, action: nil)
    private let cancelRemainingButton = NSButton(title: "Cancel Remaining", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry Failed", target: nil, action: nil)
    private let openOutputButton = NSButton(title: "Open Output", target: nil, action: nil)
    private let newBatchButton = NSButton(title: "New Batch", target: nil, action: nil)
    private var window: NSWindow!

    func show() {
        if window == nil { buildWindow() }
        if !windowHasBeenCentered { window.center(); windowHasBeenCentered = true }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(items: [BatchTranscriptionItem], activeItemID: UUID?, hasStarted: Bool,
                settings: BatchTranscriptionSettings?) {
        self.items = items
        self.activeItemID = activeItemID
        self.hasStarted = hasStarted
        self.settings = settings
        if window != nil {
            summaryLabel.stringValue = BatchTranscriptionPlan.summary(for: items)
            emptyState.isHidden = !items.isEmpty
            updateSettingsSummary()
            table.reloadData()
            updateButtons()
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Batch Transcription"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 610)

        heading.font = .boldSystemFont(ofSize: 22)
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byWordWrapping
        emptyState.font = .systemFont(ofSize: 13)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.maximumNumberOfLines = 2

        [modelValue, languageValue, speakerValue].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.textColor = .labelColor
            $0.lineBreakMode = .byTruncatingTail
        }
        modelValue.toolTip = "Whisper model used for this batch"
        languageValue.toolTip = "Transcription language used for this batch"
        speakerValue.toolTip = "Whether local speaker detection is enabled"

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        nameColumn.title = "File"
        nameColumn.width = 480
        nameColumn.minWidth = 300
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 300
        statusColumn.minWidth = 230
        let progressColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("progress"))
        progressColumn.title = "Progress"
        progressColumn.width = 250
        progressColumn.minWidth = 180
        table.addTableColumn(nameColumn)
        table.addTableColumn(statusColumn)
        table.addTableColumn(progressColumn)
        table.headerView = NSTableHeaderView()
        table.rowHeight = 62
        table.intercellSpacing = NSSize(width: 8, height: 8)
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectionChanged)
        table.doubleAction = #selector(openSelectedTranscript)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        configure(addButton, action: #selector(addFiles))
        configure(removeButton, action: #selector(removeSelected))
        configure(startButton, action: #selector(startBatch))
        configure(cancelCurrentButton, action: #selector(cancelCurrent))
        configure(cancelRemainingButton, action: #selector(cancelRemaining))
        configure(retryButton, action: #selector(retryFailed))
        configure(openOutputButton, action: #selector(openOutput))
        configure(newBatchButton, action: #selector(newBatch))
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.toolTip = "Add audio or video files to this batch"
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
        removeButton.imagePosition = .imageLeading
        removeButton.toolTip = "Remove selected files before starting the batch"
        startButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        startButton.imagePosition = .imageLeading
        cancelCurrentButton.toolTip = "Stop the file currently being transcribed"
        cancelRemainingButton.toolTip = "Cancel files that have not started"
        retryButton.toolTip = "Retry files that failed"
        openOutputButton.toolTip = "Open the output folder for the selected file"
        newBatchButton.toolTip = "Clear this completed batch and start a new one"
        startButton.keyEquivalent = "\r"
        startButton.bezelColor = .controlAccentColor
        startButton.contentTintColor = .white

        let fileButtons = NSStackView(views: [addButton, removeButton, spacer()])
        fileButtons.orientation = .horizontal
        fileButtons.spacing = 7

        let modelCard = settingCard(title: "Model", value: modelValue)
        let languageCard = settingCard(title: "Language", value: languageValue)
        let speakerCard = settingCard(title: "Speaker Detection", value: speakerValue)
        let settingsStrip = NSStackView(views: [modelCard, languageCard, speakerCard])
        settingsStrip.orientation = .horizontal
        settingsStrip.alignment = .height
        settingsStrip.distribution = .fillEqually
        settingsStrip.spacing = 10
        settingsStrip.translatesAutoresizingMaskIntoConstraints = false

        let footerButtons = NSStackView(views: [startButton, cancelCurrentButton, cancelRemainingButton,
                                                 retryButton, openOutputButton, newBatchButton])
        footerButtons.orientation = .horizontal
        footerButtons.alignment = .centerY
        footerButtons.spacing = 7
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [summaryLabel, spacer(), footerButtons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        [heading, subheading, fileButtons, settingsStrip, scroll, emptyState, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }
        window.contentView = content
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            fileButtons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            fileButtons.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            subheading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            subheading.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            settingsStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            settingsStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            settingsStrip.topAnchor.constraint(equalTo: subheading.bottomAnchor, constant: 16),
            settingsStrip.heightAnchor.constraint(equalToConstant: 74),
            scroll.leadingAnchor.constraint(equalTo: settingsStrip.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: settingsStrip.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: settingsStrip.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            summaryLabel.widthAnchor.constraint(equalToConstant: 205),
            startButton.widthAnchor.constraint(equalToConstant: 112),
            cancelCurrentButton.widthAnchor.constraint(equalToConstant: 112),
            cancelRemainingButton.widthAnchor.constraint(equalToConstant: 128),
            retryButton.widthAnchor.constraint(equalToConstant: 100),
            openOutputButton.widthAnchor.constraint(equalToConstant: 104),
            newBatchButton.widthAnchor.constraint(equalToConstant: 94)
        ])
        update(items: items, activeItemID: activeItemID, hasStarted: hasStarted, settings: settings)
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
    }

    private func settingCard(title: String, value: NSTextField) -> NSBox {
        let content = NSView()
        let box = NSBox()
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 12, height: 9)
        value.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        box.contentView = content
        return box
    }

    private func updateSettingsSummary() {
        guard let settings else {
            modelValue.stringValue = "—"
            languageValue.stringValue = "—"
            speakerValue.stringValue = "—"
            return
        }
        modelValue.stringValue = settings.modelDisplayName
        languageValue.stringValue = settings.languageDisplayName
        speakerValue.stringValue = settings.speakerDisplayName
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func updateButtons() {
        let selectedRows = table.selectedRowIndexes
        let selectedItems = selectedRows.compactMap { items.indices.contains($0) ? items[$0] : nil }
        let draft = !hasStarted
        addButton.isEnabled = draft
        removeButton.isEnabled = draft && !selectedItems.isEmpty && selectedItems.allSatisfy { $0.state == .ready }
        startButton.isEnabled = draft && items.contains { $0.state == .ready }
        cancelCurrentButton.isEnabled = activeItemID != nil
        cancelRemainingButton.isEnabled = items.contains { $0.state == .queued || $0.state == .paused }
        retryButton.isEnabled = items.contains { $0.state == .failed }
        openOutputButton.isEnabled = selectedItems.count == 1
        newBatchButton.isEnabled = hasStarted && activeItemID == nil && items.allSatisfy { $0.state.isTerminal }
        emptyState.isHidden = !items.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let tableColumn else { return nil }
        let item = items[row]
        let identifier = tableColumn.identifier
        switch identifier.rawValue {
        case "file":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BatchFileCellView)
                ?? BatchFileCellView(frame: .zero)
            cell.identifier = identifier
            cell.configure(with: item)
            return cell
        case "status":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BatchStatusCellView)
                ?? BatchStatusCellView(frame: .zero)
            cell.identifier = identifier
            cell.configure(with: item)
            return cell
        case "progress":
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BatchProgressCellView)
                ?? BatchProgressCellView(frame: .zero)
            cell.identifier = identifier
            cell.configure(with: item.state)
            return cell
        default:
            return nil
        }
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Files to Batch"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK else { return }
        onAddFiles?(panel.urls)
    }

    @objc private func removeSelected() {
        let ids = table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil }
        guard !ids.isEmpty else { return }
        onRemoveFiles?(ids)
    }

    @objc private func startBatch() { onStart?() }
    @objc private func cancelCurrent() { onCancelCurrent?() }
    @objc private func cancelRemaining() { onCancelRemaining?() }
    @objc private func retryFailed() { onRetryFailed?() }

    @objc private func openOutput() {
        guard table.selectedRow >= 0, items.indices.contains(table.selectedRow) else { return }
        onOpenOutput?(items[table.selectedRow].id)
    }

    @objc private func openSelectedTranscript() {
        guard table.selectedRow >= 0, items.indices.contains(table.selectedRow),
              items[table.selectedRow].state == .completed else { return }
        onSelectResult?(items[table.selectedRow].id)
    }

    @objc private func selectionChanged() {
        updateButtons()
        guard table.selectedRow >= 0, items.indices.contains(table.selectedRow),
              items[table.selectedRow].state == .completed else { return }
        onSelectResult?(items[table.selectedRow].id)
    }

    @objc private func newBatch() { onNewBatch?() }
}
