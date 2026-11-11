import AppKit
import AVFoundation
import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home
    case queue
    case transcriptions
    case meetings
    case recentlyDeleted
    case folders
    case people
    case settings
    case transcript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .queue: return "Queue"
        case .transcriptions: return "Transcriptions"
        case .meetings: return "Meetings"
        case .recentlyDeleted: return "Recently Deleted"
        case .folders: return "Folders"
        case .people: return "People"
        case .settings: return "Settings"
        case .transcript: return "Transcript"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .queue: return "tray.full"
        case .transcriptions: return "text.alignleft"
        case .meetings: return "person.2.wave.2"
        case .recentlyDeleted: return "trash"
        case .folders: return "folder"
        case .people: return "person.crop.circle"
        case .settings: return "gearshape"
        case .transcript: return "waveform"
        }
    }
}

enum WorkspaceTranscriptMode: String, CaseIterable, Identifiable {
    case transcript = "Transcript"
    case summary = "Summary"
    case chat = "Chat"

    var id: String { rawValue }
}

struct WorkspaceModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let downloadSize: String
    let isInstalled: Bool
    let isEnglishOnly: Bool
}

struct WorkspaceChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

enum WorkspacePermanentDeletePrompt: Equatable {
    case one(UUID)
    case all([UUID])

    var title: String {
        switch self {
        case .one: return "Permanently remove this transcript?"
        case .all: return "Empty Recently Deleted?"
        }
    }

    var message: String {
        switch self {
        case .one: return "This removes the library entry permanently. The original media and exports stay on this Mac."
        case .all: return "These library entries cannot be restored afterward. The original media and exports stay on this Mac."
        }
    }

    var ids: [UUID] {
        switch self {
        case .one(let id): return [id]
        case .all(let ids): return ids
        }
    }
}

final class WorkspaceState: ObservableObject {
    @Published var destination: WorkspaceDestination = .home
    @Published var transcriptMode: WorkspaceTranscriptMode = .transcript
    @Published var inspectorVisible = true
    @Published var currentFileName = "No media selected"
    @Published var sourcePath: String?
    @Published var status = "Choose an audio or video file to get started."
    @Published var segments: [TranscriptSegment] = []
    @Published var speakerNames: [Int: String] = [:]
    @Published var hasUnsavedChanges = false
    var hasTranscriptContentChanges = false
    @Published var isBusy = false
    @Published var isTranscribing = false
    @Published var isDownloadingModel = false
    @Published var isMeeting = false
    @Published var isSpeakerDetectionEnabled = true
    @Published var isSummaryBusy = false
    @Published var isChatBusy = false
    @Published var modelOptions: [WorkspaceModelOption] = []
    @Published var selectedModelID = "large-v3-turbo"
    @Published var selectedLanguage = "auto"
    @Published var searchText = ""
    @Published var history: [WorkspaceLibraryEntry] = []
    @Published var libraryWarning: String?
    @Published var activities: [ActivityItem] = []
    @Published var activeHistoryID: UUID?
    @Published var duration: Double = 0
    @Published var transcriptionSeconds: Double?
    @Published var summaryText = ""
    @Published var chatMessages: [WorkspaceChatMessage] = []
    @Published var chatDraft = ""
    @Published var lastCopiedMessage = ""
    @Published var settingsPage = "General"
    @Published var urlText = ""
    @Published var replaceText = ""
    @Published var showingReplace = false
    @Published var deleteConfirmation: WorkspaceLibraryEntry?
    @Published var permanentDeletePrompt: WorkspacePermanentDeletePrompt?

    var selectedModel: WorkspaceModelOption? { modelOptions.first { $0.id == selectedModelID } }
    var canTranscribe: Bool { sourcePath != nil && !isTranscriptEditingLocked }
    var isTranscriptEditingLocked: Bool { isBusy || isMeeting || isSummaryBusy || isChatBusy }
    var hasTranscript: Bool { !segments.isEmpty }
    var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
    var characterCount: Int { segments.reduce(0) { $0 + $1.text.count } }
    var speakerIDs: [Int] { Array(Set(segments.compactMap(\.speakerID))).sorted() }
    var selectedEntry: WorkspaceLibraryEntry? { history.first { $0.id == activeHistoryID } }

    func editSegment(at index: Int, text: String) {
        guard !isTranscriptEditingLocked, segments.indices.contains(index), segments[index].text != text else { return }
        segments[index].text = text
        markTranscriptContentChanged()
    }

    func setSpeakerName(_ name: String, id: Int) {
        guard !isTranscriptEditingLocked, speakerNames[id] != name else { return }
        speakerNames[id] = name
        markTranscriptContentChanged()
    }

    func setSpeaker(_ speakerID: Int?, at index: Int) {
        guard !isTranscriptEditingLocked, segments.indices.contains(index), segments[index].speakerID != speakerID else { return }
        segments[index].speakerID = speakerID
        markTranscriptContentChanged()
    }

    func toggleFavorite(at index: Int) {
        guard !isTranscriptEditingLocked, segments.indices.contains(index) else { return }
        segments[index].isFavorite.toggle()
        hasUnsavedChanges = true
    }

    private func markTranscriptContentChanged() {
        hasUnsavedChanges = true
        hasTranscriptContentChanges = true
        summaryText = ""
        chatMessages = []
    }
}

struct WorkspaceActions {
    var refresh: () -> Void = {}
    var openFile: () -> Void = {}
    var openBatch: () -> Void = {}
    var transcribe: () -> Void = {}
    var toggleMeeting: () -> Void = {}
    var openRecordings: () -> Void = {}
    var openActivity: () -> Void = {}
    var openMeetingSettings: () -> Void = {}
    var manageModel: () -> Void = {}
    var selectModel: (String) -> Void = { _ in }
    var selectLanguage: (String) -> Void = { _ in }
    var setSpeakerDetection: (Bool) -> Void = { _ in }
    var copyTranscript: () -> Void = {}
    var exportTranscript: (String) -> Void = { _ in }
    var commitEdits: () -> Void = {}
    var openTranscript: (UUID) -> Void = { _ in }
    var softDeleteTranscript: (UUID) -> Void = { _ in }
    var restoreTranscript: (UUID) -> Void = { _ in }
    var permanentlyDeleteTranscript: (UUID) -> Void = { _ in }
    var dismissActivity: (UUID) -> Void = { _ in }
    var clearCompletedActivity: () -> Void = {}
    var openFolder: (String) -> Void = { _ in }
    var generateSummary: () -> Void = {}
    var submitChat: (String) -> Void = { _ in }
    var openResults: () -> Void = {}
}

struct WorkspaceView: View {
    @ObservedObject var state: WorkspaceState
    let actions: WorkspaceActions

    @StateObject private var playback = WorkspacePlaybackController()
    @AppStorage("Workspace.Appearance") private var appearance = "system"

    private let sidebarWidth: CGFloat = 224

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                destinationBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            actions.refresh()
            playback.load(path: state.sourcePath)
        }
        .onChange(of: state.sourcePath) { newValue in playback.load(path: newValue) }
        .task {
            while !Task.isCancelled {
                actions.refresh()
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
        .alert("Move to Recently Deleted?", isPresented: Binding(
            get: { state.deleteConfirmation != nil },
            set: { if !$0 { state.deleteConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) { state.deleteConfirmation = nil }
            Button("Move to Recently Deleted", role: .destructive) {
                if let entry = state.deleteConfirmation { actions.softDeleteTranscript(entry.id) }
                state.deleteConfirmation = nil
            }
        } message: {
            Text("The transcript and its source files will stay on this Mac. You can restore the transcript from Recently Deleted.")
        }
        .confirmationDialog(
            state.permanentDeletePrompt?.title ?? "Permanently remove transcript?",
            isPresented: Binding(
                get: { state.permanentDeletePrompt != nil },
                set: { if !$0 { state.permanentDeletePrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let prompt = state.permanentDeletePrompt {
                    for id in prompt.ids { actions.permanentlyDeleteTranscript(id) }
                }
                state.permanentDeletePrompt = nil
            }
            Button("Cancel", role: .cancel) { state.permanentDeletePrompt = nil }
        } message: {
            Text(state.permanentDeletePrompt?.message ?? "")
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe to Text").font(.system(size: 13, weight: .semibold))
                    Text("On-device workspace").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 15)
            .padding(.bottom, 9)

            VStack(spacing: 3) {
                sidebarButton(.home)
                sidebarButton(.queue, badge: state.activities.filter { $0.state == .queued || $0.state == .running || $0.state == .recording }.count)
            }
            .padding(.horizontal, 9)

            sectionLabel("HISTORY")
            VStack(spacing: 3) {
                sidebarButton(.transcriptions)
                sidebarButton(.meetings)
                sidebarButton(.recentlyDeleted, badge: state.history.filter(\.isDeleted).count)
            }
            .padding(.horizontal, 9)

            if state.sourcePath != nil {
                sectionLabel("OPEN DOCUMENT")
                Button {
                    state.destination = .transcript
                    state.transcriptMode = .transcript
                } label: {
                    Label(state.currentFileName, systemImage: "waveform")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(state.destination == .transcript ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(state.currentFileName)
                .padding(.horizontal, 9)
            }

            sectionLabel("ORGANIZE")
            VStack(spacing: 3) {
                sidebarButton(.folders)
                sidebarButton(.people)
            }
            .padding(.horizontal, 9)

            Spacer(minLength: 4)
            HStack(spacing: 9) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
                Text("Media stays on this Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            VStack(spacing: 3) {
                Button { actions.openActivity(); state.destination = .queue } label: {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                sidebarButton(.settings)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func sidebarButton(_ destination: WorkspaceDestination, badge: Int = 0) -> some View {
        Button { state.destination = destination } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.symbol).frame(width: 17)
                Text(destination.title).lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : String(badge))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5, weight: state.destination == destination ? .medium : .regular))
            .foregroundStyle(state.destination == destination ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(state.destination == destination ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if state.destination == .transcript {
                Button { state.destination = .home } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .help("Back to Home")
            }
            Text(state.destination == .transcript ? state.currentFileName : state.destination.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if state.destination == .home || state.destination == .transcript {
                modelMenu
                languageMenu
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                if !state.searchText.isEmpty {
                    Button { state.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(.bar)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(state.modelOptions) { model in
                Button {
                    actions.selectModel(model.id)
                } label: {
                    if model.id == state.selectedModelID {
                        Label(model.title, systemImage: "checkmark")
                    } else {
                        Text(model.title)
                    }
                }
            }
            Divider()
            Button("Manage Local Models…", systemImage: "arrow.down.circle") { state.settingsPage = "Models"; state.destination = .settings }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(state.selectedModel?.title ?? "Choose Model").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(state.isBusy || state.isMeeting || state.isSummaryBusy || state.isChatBusy)
        .help(state.selectedModel?.detail ?? "Choose a local transcription model")
    }

    private var languageMenu: some View {
        Menu {
            ForEach(languageOptions, id: \.id) { option in
                Button {
                    actions.selectLanguage(option.id)
                } label: {
                    if state.selectedLanguage == option.id {
                        Label(option.title, systemImage: "checkmark")
                    } else { Text(option.title) }
                }
                .disabled(state.selectedModel?.isEnglishOnly == true && option.id != "en")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble")
                Text(languageTitle(state.selectedLanguage))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(state.isBusy || state.isMeeting || state.isSummaryBusy || state.isChatBusy)
        .help(state.selectedModel?.isEnglishOnly == true ? "This English-only model supports English." : "Choose the spoken language")
    }

    private var languageOptions: [(id: String, title: String)] {
        [("auto", "Auto detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
         ("de", "German"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean")]
    }

    private func languageTitle(_ id: String) -> String {
        languageOptions.first(where: { $0.id == id })?.title ?? id.uppercased()
    }

    @ViewBuilder private var destinationBody: some View {
        switch state.destination {
        case .home: homeView
        case .queue: queueView
        case .transcriptions: libraryView(title: "Transcriptions", entries: visibleHistory.filter { $0.kind == .transcription && !$0.isDeleted })
        case .meetings: libraryView(title: "Meetings", entries: visibleHistory.filter { $0.kind == .meeting && !$0.isDeleted })
        case .recentlyDeleted: recentlyDeletedView
        case .folders: foldersView
        case .people: peopleView
        case .settings: settingsView
        case .transcript: transcriptView
        }
    }

    private var visibleHistory: [WorkspaceLibraryEntry] {
        guard !state.searchText.isEmpty else { return state.history }
        return state.history.filter {
            $0.title.localizedCaseInsensitiveContains(state.searchText) ||
            $0.speakerNames.values.contains(where: { $0.localizedCaseInsensitiveContains(state.searchText) }) ||
            $0.segments.contains(where: { $0.text.localizedCaseInsensitiveContains(state.searchText) })
        }
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("What would you like to transcribe?")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("Transcribe audio and video locally with Whisper.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.top, 25)

                if let warning = state.libraryWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        TextField("Paste an audio or video URL", text: $state.urlText)
                            .textFieldStyle(.plain)
                            .disabled(true)
                            .help("URL intake is not implemented in this build. Use Open Files for local media.")
                        Button("Open Files…") { actions.openFile() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                    Text("Local files are processed on this Mac. Direct links and YouTube are not available in this build.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let sourcePath = state.sourcePath {
                    HStack(spacing: 11) {
                        Image(systemName: "waveform").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.currentFileName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(sourcePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(state.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button(state.isTranscribing ? "Cancel" : "Transcribe") { actions.transcribe() }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isMeeting || (state.isBusy && !state.isTranscribing) || state.isSummaryBusy || state.isChatBusy)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("QUICK ACTIONS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        actionCard("Open Files", subtitle: "Choose audio or video", symbol: "folder", tint: .blue) { actions.openFile() }
                            .disabled(state.isBusy || state.isMeeting || state.isSummaryBusy || state.isChatBusy)
                        actionCard("Batch Transcribe", subtitle: "Process several files", symbol: "square.stack.3d.up", tint: .purple) { actions.openBatch() }
                            .disabled(state.isBusy || state.isMeeting || state.isSummaryBusy || state.isChatBusy)
                        actionCard(state.isMeeting ? "Stop Meeting" : "Record Meeting", subtitle: "Capture mic and system audio", symbol: "record.circle", tint: state.isMeeting ? .red : .orange) { actions.toggleMeeting() }
                            .disabled(!state.isMeeting && (state.isBusy || state.isSummaryBusy || state.isChatBusy))
                        actionCard("Manage Models", subtitle: "Download or remove local models", symbol: "arrow.down.circle", tint: .green) { state.settingsPage = "Models"; state.destination = .settings }
                        unavailableCard("Voice Memo", subtitle: "Record a quick note", symbol: "mic", reason: "Voice memo capture is not implemented in this build.")
                        unavailableCard("App Audio", subtitle: "Capture a single app", symbol: "waveform.badge.mic", reason: "Per-app audio capture is not implemented in this build.")
                        unavailableCard("Live Captions", subtitle: "Transcribe as you listen", symbol: "captions.bubble", reason: "Live caption overlays are not implemented in this build.")
                        unavailableCard("Podcast Tracks", subtitle: "Work with separate tracks", symbol: "person.2.wave.2", reason: "Multi-track podcast editing is not implemented in this build.")
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent transcripts").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button("View All") { state.destination = .transcriptions }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    let recent = visibleHistory.filter { !$0.isDeleted }.prefix(4)
                    if recent.isEmpty {
                        emptyState(symbol: "text.alignleft", title: "No transcripts yet", message: "Choose a local audio or video file to create your first transcript.")
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(Array(recent)) { entry in transcriptCard(entry) }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(.green)
                    Text("Audio, transcripts, and local notes stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 26)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func actionCard(_ title: String, subtitle: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.68), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    private func unavailableCard(_ title: String, subtitle: String, symbol: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.tertiary)
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.045)))
        .help(reason)
        .accessibilityLabel("\(title). \(reason)")
    }

    private func transcriptCard(_ entry: WorkspaceLibraryEntry) -> some View {
        Button { actions.openTranscript(entry.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: entry.kind == .meeting ? "person.2.wave.2" : "waveform")
                        .foregroundStyle(entry.kind == .meeting ? .orange : .blue)
                    Text(entry.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(entry.segments.first?.text ?? "No transcript text")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Label("\(entry.wordCount) words", systemImage: "text.alignleft")
                    Label(formatDuration(entry.duration), systemImage: "clock")
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open Transcript", systemImage: "text.alignleft") { actions.openTranscript(entry.id) }
            Button("Show in Finder", systemImage: "folder") { actions.openFolder(entry.folderPath) }
            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) { state.deleteConfirmation = entry }
        }
    }

    private var queueView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Queue").font(.system(size: 23, weight: .semibold))
                        Text("Transcription and recording activity on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear Completed") { actions.clearCompletedActivity() }
                        .disabled(!state.activities.contains { $0.state == .completed || $0.state == .cancelled })
                    Button("Batch Transcribe…") { actions.openBatch() }.buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || state.isMeeting || state.isSummaryBusy || state.isChatBusy)
                }
                .padding(.top, 21)

                if state.activities.isEmpty {
                    emptyState(symbol: "tray", title: "Queue is empty", message: "New transcription jobs and recordings will appear here.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(state.activities) { item in activityRow(item) }
                    }
                }
            }
            .padding(.horizontal, 25)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func activityRow(_ item: ActivityItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .recording ? "record.circle" : item.kind == .summary ? "sparkles" : "waveform")
                .font(.system(size: 17)).foregroundStyle(activityColor(item.state)).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(item.state.rawValue.capitalized).font(.caption).foregroundStyle(activityColor(item.state))
            if item.state == .completed, let entry = state.history.first(where: { $0.sourcePath == item.sourcePath && !$0.isDeleted }) {
                Button("Open Transcript") { actions.openTranscript(entry.id) }.controlSize(.small)
            }
            if item.state == .completed || item.state == .failed || item.state == .cancelled {
                Button { actions.dismissActivity(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss from Queue")
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
    }

    private func activityColor(_ state: ActivityState) -> Color {
        switch state {
        case .completed: return .green
        case .failed, .interrupted: return .red
        case .recording, .running: return .orange
        case .queued, .paused: return .blue
        case .cancelled: return .secondary
        }
    }

    private func libraryView(title: String, entries: [WorkspaceLibraryEntry]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 23, weight: .semibold))
                        Text("Stored locally in your transcription library.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Files…") { actions.openFile() }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 21)
                if entries.isEmpty {
                    emptyState(symbol: title == "Meetings" ? "person.2.wave.2" : "text.alignleft",
                               title: "No items yet", message: "Completed \(title.lowercased()) will appear here.")
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in transcriptCard(entry) }
                    }
                }
            }
            .padding(.horizontal, 25)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var recentlyDeletedView: some View {
        let deleted = visibleHistory.filter(\.isDeleted)
        return ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recently Deleted").font(.system(size: 23, weight: .semibold))
                        Text("Restore a transcript or remove its library entry permanently.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Empty Recently Deleted", role: .destructive) {
                        state.permanentDeletePrompt = .all(state.history.filter(\.isDeleted).map(\.id))
                    }
                    .disabled(deleted.isEmpty)
                }
                .padding(.top, 21)
                if deleted.isEmpty {
                    emptyState(symbol: "trash", title: "Nothing here", message: "Transcripts you delete will be kept here until you remove them permanently.")
                } else {
                    ForEach(deleted) { entry in
                        HStack {
                            transcriptCard(entry)
                            Button("Restore") { actions.restoreTranscript(entry.id) }
                            Button(role: .destructive) { state.permanentDeletePrompt = .one(entry.id) } label: { Image(systemName: "trash") }
                                .help("Permanently remove this transcript from the library")
                        }
                    }
                }
            }
            .padding(.horizontal, 25)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var foldersView: some View {
        let folders = Dictionary(grouping: state.history.filter { !$0.isDeleted }, by: \.folderPath)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folders").font(.system(size: 23, weight: .semibold))
                    Text("Browse the local folders that contain your source media and exports.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 21)
                if folders.isEmpty {
                    emptyState(symbol: "folder", title: "No folders yet", message: "Folders appear after the first transcript is saved.")
                } else {
                    ForEach(folders.keys.sorted(), id: \.self) { path in
                        let entries = folders[path] ?? []
                        Button { actions.openFolder(path) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").foregroundStyle(.blue).font(.system(size: 19))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(entries.count) transcript\(entries.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "arrow.up.right.square").foregroundStyle(.tertiary)
                            }
                            .padding(13).background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 25)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var peopleView: some View {
        let speakers = speakerDirectory
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("People").font(.system(size: 23, weight: .semibold))
                    Text("Speaker names collected from your saved transcripts.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 21)
                if speakers.isEmpty {
                    emptyState(symbol: "person.crop.circle", title: "No speakers yet", message: "Speaker labels appear here after a transcript includes diarization results.")
                } else {
                    ForEach(speakers) { speaker in
                        HStack(spacing: 11) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 25)).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(speaker.name).font(.system(size: 13, weight: .medium))
                                Text("\(speaker.transcriptCount) transcript\(speaker.transcriptCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("View Transcripts") { state.destination = .transcriptions; state.searchText = speaker.name }
                                .controlSize(.small)
                        }
                        .padding(12).background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(.horizontal, 25)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var speakerDirectory: [SpeakerDirectoryEntry] {
        var counts: [String: Int] = [:]
        for entry in state.history where !entry.isDeleted {
            for name in entry.speakerNames.values { counts[name, default: 0] += 1 }
        }
        return counts.map { SpeakerDirectoryEntry(name: $0.key, transcriptCount: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var transcriptView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Picker("Transcript mode", selection: $state.transcriptMode) {
                    ForEach(WorkspaceTranscriptMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                if state.hasTranscript {
                    if state.transcriptMode == .transcript && state.hasUnsavedChanges {
                        Button("Save Changes") { actions.commitEdits() }
                            .keyboardShortcut("s", modifiers: .command)
                            .buttonStyle(.borderedProminent)
                    }
                    Button { actions.copyTranscript() } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .disabled(!state.hasTranscript)
                    Menu {
                        Button("Transcript · TXT") { actions.exportTranscript("txt") }
                        Button("Subtitles · SRT") { actions.exportTranscript("srt") }
                        Button("Subtitles · WebVTT") { actions.exportTranscript("vtt") }
                        Divider()
                        Button("Whisper archive") { actions.exportTranscript("whisper") }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up").padding(.horizontal, 11).padding(.vertical, 6)
                    }
                    .menuStyle(.borderlessButton)
                    Button { state.inspectorVisible.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(state.inspectorVisible ? "Hide Info" : "Show Info")
                } else if state.transcriptMode == .transcript, state.sourcePath != nil {
                    Button(state.isTranscribing ? "Cancel" : "Transcribe Again") { actions.transcribe() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isMeeting || (state.isBusy && !state.isTranscribing) || state.isSummaryBusy || state.isChatBusy)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Divider() }

            switch state.transcriptMode {
            case .transcript: transcriptEditor
            case .summary: summaryPanel
            case .chat: chatPanel
            }
        }
    }

    private var transcriptEditor: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !state.hasTranscript {
                    emptyState(symbol: "waveform", title: "No transcript loaded", message: "Open a media file and transcribe it to see editable segments here.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack {
                        Text("\(state.segments.count) segments")
                        Text("·")
                        Text("\(state.wordCount) words")
                        Spacer()
                        if state.showingReplace {
                            TextField("Find", text: $state.searchText).frame(width: 130)
                            TextField("Replace with", text: $state.replaceText).frame(width: 130)
                            Button("Replace All") { replaceAll() }.disabled(state.searchText.isEmpty)
                        }
                        Button { state.showingReplace.toggle() } label: { Image(systemName: "arrow.left.arrow.right") }
                            .buttonStyle(.plain).help("Find and replace in transcript")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(state.segments.enumerated()), id: \.element.id) { index, segment in
                                    if matchesSearch(segment) {
                                        segmentRow(segment, index: index)
                                            .id(segment.id)
                                    }
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.bottom, 24)
                        }
                        .onChange(of: playback.currentTime) { time in
                            guard state.hasTranscript else { return }
                            if let active = state.segments.first(where: { time >= $0.start && time <= $0.end }) {
                                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(active.id, anchor: .center) }
                            }
                        }
                    }
                }
                playbackBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.inspectorVisible {
                Divider()
                infoInspector.frame(width: 265)
            }
        }
    }

    private func matchesSearch(_ segment: TranscriptSegment) -> Bool {
        state.searchText.isEmpty || segment.text.localizedCaseInsensitiveContains(state.searchText)
    }

    private func segmentRow(_ segment: TranscriptSegment, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Button { playback.seek(to: segment.start); playback.play() } label: {
                    Text(timestamp(segment.start))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Jump to this point in the recording")

                if let speakerID = segment.speakerID {
                    Menu {
                        Button("No speaker") { state.setSpeaker(nil, at: index) }
                        ForEach(state.speakerIDs, id: \.self) { candidate in
                            Button(state.speakerNames[candidate] ?? "Speaker \(candidate + 1)") { state.setSpeaker(candidate, at: index) }
                        }
                    } label: {
                        Text(state.speakerNames[speakerID] ?? "Speaker \(speakerID + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(state.isTranscriptEditingLocked)
                }
                Spacer()
                Button { state.toggleFavorite(at: index) } label: {
                    Image(systemName: segment.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(segment.isFavorite ? Color.yellow : Color.gray.opacity(0.65))
                }
                .buttonStyle(.plain)
                .disabled(state.isTranscriptEditingLocked)
                .help(segment.isFavorite ? "Remove favorite" : "Favorite this segment")
            }
            TextField("Transcript segment", text: Binding(
                get: { state.segments.indices.contains(index) ? state.segments[index].text : "" },
                set: { state.editSegment(at: index, text: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...8)
            .padding(.leading, 2)
            .disabled(state.isTranscriptEditingLocked)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
    }

    private var playbackBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(state.sourcePath == nil)
                Text(formatDuration(playback.currentTime)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }), in: 0...max(1, playback.duration))
                    .disabled(playback.duration <= 0)
                Text(formatDuration(playback.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate.formatted(.number.precision(.fractionLength(2))))×") { playback.setRate(Float(rate)) }
                    }
                } label: { Text("\(playback.rate.formatted(.number.precision(.fractionLength(2))))×").font(.caption.monospacedDigit()) }
                    .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.56))
        .overlay(alignment: .top) { Divider() }
    }

    private var infoInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("Info").font(.system(size: 14, weight: .semibold)).padding(.top, 15)
                inspectorGroup("MODEL & LANGUAGE") {
                    infoRow("Model", state.selectedModel?.title ?? "—")
                    infoRow("Language", languageTitle(state.selectedLanguage))
                    Toggle("Detect speakers", isOn: Binding(get: { state.isSpeakerDetectionEnabled }, set: actions.setSpeakerDetection))
                        .font(.caption)
                        .disabled(state.isBusy || state.isMeeting)
                }
                inspectorGroup("PROPERTIES") {
                    infoRow("Duration", formatDuration(max(playback.duration, state.duration)))
                    infoRow("Created", state.selectedEntry?.createdAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    infoRow("Updated", state.selectedEntry?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                inspectorGroup("TRANSCRIPTION DETAILS") {
                    infoRow("Engine", "Whisper C++")
                    infoRow("Words", state.wordCount.formatted())
                    infoRow("Characters", state.characterCount.formatted())
                    infoRow("Speakers", state.speakerIDs.count.formatted())
                    infoRow("Processing", state.transcriptionSeconds.map(formatDuration) ?? "—")
                }
                if !state.speakerIDs.isEmpty {
                    inspectorGroup("SPEAKERS") {
                        ForEach(state.speakerIDs, id: \.self) { speakerID in
                            TextField("Speaker \(speakerID + 1)", text: Binding(
                                get: { state.speakerNames[speakerID] ?? "Speaker \(speakerID + 1)" },
                                set: { state.setSpeakerName($0, id: speakerID) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .disabled(state.isTranscriptEditingLocked)
                        }
                    }
                }
                if !state.status.isEmpty {
                    inspectorGroup("STATUS") {
                        Text(state.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Show in Finder", systemImage: "folder") { actions.openResults() }
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func inspectorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.65).foregroundStyle(.secondary)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.caption).lineLimit(2).multilineTextAlignment(.trailing)
        }
    }

    private var summaryPanel: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("AI Summary").font(.system(size: 19, weight: .semibold))
                    Spacer()
                    if !state.summaryText.isEmpty {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.summaryText, forType: .string) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { state.summaryText = "" } label: { Image(systemName: "trash") }.help("Clear summary")
                    }
                }
                if state.summaryText.isEmpty && !state.isSummaryBusy {
                    emptyState(symbol: "sparkles", title: "Generate local notes", message: "A local Qwen model can create a summary, key points, decisions, and action items from this transcript.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { Text(state.summaryText.isEmpty ? state.status : state.summaryText).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.vertical, 8) }
                        .font(.system(size: 13))
                }
                HStack {
                    Text("Generated with the local notes model. First use may download about 2.5 GB.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(state.isSummaryBusy ? "Working…" : "Summarize") { actions.generateSummary() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.hasTranscript || state.isSummaryBusy || state.isChatBusy || state.isBusy)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state.inspectorVisible {
                Divider()
                VStack(alignment: .leading, spacing: 13) {
                    Text("Summary Options").font(.system(size: 13, weight: .semibold))
                    Text("This build uses the local meeting-notes format: Summary, Key points, Decisions, and Action items.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Label("Include speaker names", systemImage: "person.wave.2").font(.caption)
                    Label("Include timestamps", systemImage: "clock").font(.caption)
                    Spacer()
                }
                .padding(16).frame(width: 250, alignment: .leading)
            }
        }
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask about this transcript").font(.system(size: 19, weight: .semibold))
                    Text("Answers use the local notes model and this transcript only.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.isChatBusy { ProgressView().controlSize(.small) }
            }
            if state.chatMessages.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(["Summarize", "List action items", "Find key points", "What was decided?", "Extract questions", "Who said what?"], id: \.self) { prompt in
                        Button(prompt) { state.chatDraft = prompt; submitChat() }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!state.hasTranscript || state.isChatBusy || state.isSummaryBusy)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(state.chatMessages) { message in
                            HStack {
                                if message.role == .assistant { Image(systemName: "sparkles").foregroundStyle(.purple) }
                                Text(message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 13))
                            .padding(12)
                            .background(message.role == .user ? Color.accentColor.opacity(0.11) : Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 9) {
                TextField("Ask a question about the transcript", text: $state.chatDraft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .padding(11)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                    .onSubmit { submitChat() }
                Button { submitChat() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(state.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.hasTranscript || state.isChatBusy || state.isSummaryBusy)
            }
            Text("Local model setup may download about 2.5 GB on first use.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func submitChat() {
        let question = state.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        state.chatDraft = ""
        state.chatMessages.append(WorkspaceChatMessage(role: .user, text: question))
        actions.submitChat(question)
    }

    private var settingsView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PREFERENCES").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary).padding(.horizontal, 11).padding(.bottom, 5)
                ForEach(["General", "Transcription", "Local Models", "Meetings", "Export", "AI & Chat", "About"], id: \.self) { page in
                    Button { state.settingsPage = page } label: {
                        HStack(spacing: 8) {
                            Image(systemName: settingsSymbol(page)).frame(width: 16)
                            Text(page)
                        }
                        .font(.system(size: 11.5, weight: state.settingsPage == page ? .medium : .regular))
                        .foregroundStyle(state.settingsPage == page ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(state.settingsPage == page ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(13)
            .frame(width: 188)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            Divider()
            settingsDetail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func settingsSymbol(_ page: String) -> String {
        switch page {
        case "General": return "gearshape"
        case "Transcription": return "waveform"
        case "Local Models": return "arrow.down.circle"
        case "Meetings": return "person.2.wave.2"
        case "Export": return "square.and.arrow.up"
        case "AI & Chat": return "sparkles"
        default: return "info.circle"
        }
    }

    @ViewBuilder private var settingsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(state.settingsPage).font(.system(size: 21, weight: .semibold))
                switch state.settingsPage {
                case "General":
                    settingsCard("Appearance", detail: "Choose how this workspace follows macOS appearance.") {
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Dark").tag("dark")
                            Text("Light").tag("light")
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                    }
                    settingsCard("Library", detail: "Transcripts are stored locally. Removing a transcript moves it to Recently Deleted; source media is never removed.") {
                        Label("Local JSON library with restore", systemImage: "externaldrive").font(.caption)
                    }
                case "Transcription":
                    settingsCard("Default model", detail: "The selected local model is used for new transcription jobs.") {
                        modelMenu
                        languageMenu
                    }
                    settingsCard("Speaker detection", detail: "Speaker recognition runs locally and may download its model on first use.") {
                        Toggle("Detect speakers on new files", isOn: Binding(get: { state.isSpeakerDetectionEnabled }, set: actions.setSpeakerDetection))
                    }
                case "Local Models":
                    settingsCard("Whisper models", detail: "Model files are stored in Application Support and can be removed from this Mac.") {
                        ForEach(state.modelOptions) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.title).font(.system(size: 12, weight: .medium))
                                    Text(model.isInstalled ? "Downloaded · \(model.downloadSize)" : "Not downloaded · \(model.downloadSize)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.id == state.selectedModelID {
                                    Text("Selected").font(.caption).foregroundStyle(.green)
                                }
                                let isDownloading = state.isDownloadingModel && state.selectedModelID == model.id
                                Button(isDownloading ? "Cancel" : model.isInstalled ? "Remove" : "Download") {
                                    actions.selectModel(model.id); actions.manageModel()
                                }
                                .controlSize(.small)
                                .disabled((state.isBusy && !isDownloading) || state.isSummaryBusy || state.isChatBusy)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                case "Meetings":
                    settingsCard("Meeting capture", detail: "Meeting audio capture and meeting detection use the existing local capture controls.") {
                        HStack {
                            Button(state.isMeeting ? "Stop Meeting" : "Start Meeting") { actions.toggleMeeting() }.buttonStyle(.borderedProminent)
                                .disabled(!state.isMeeting && (state.isBusy || state.isSummaryBusy || state.isChatBusy))
                            Button("Meeting Settings…") { actions.openMeetingSettings() }
                            Button("Open Recordings") { actions.openRecordings() }
                        }
                    }
                case "Export":
                    settingsCard("Available formats", detail: "Exports are written beside the source file unless you choose a destination in the save panel.") {
                        Label("Transcript · TXT", systemImage: "checkmark.circle.fill")
                        Label("Subtitles · SRT", systemImage: "checkmark.circle.fill")
                        Label("Subtitles · WebVTT", systemImage: "checkmark.circle.fill")
                        Label("Portable .whisper archive", systemImage: "checkmark.circle.fill")
                    }
                    settingsCard("Batch export", detail: "Batch jobs currently save TXT, SRT, and WebVTT next to each source file.") {
                        Button("Open Batch Transcription…") { actions.openBatch() }
                    }
                case "AI & Chat":
                    settingsCard("Local notes and transcript chat", detail: "A local Qwen model generates meeting notes and answers questions. The first request may download about 2.5 GB.") {
                        Text(LocalMeetingSummarizer.isModelInstalled ? "Local notes model is installed." : "Local notes model is not installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    settingsCard("About this build", detail: "Transcribe to Text · local build") {
                        Text("This workspace reuses the app’s local Whisper C++ engine, batch queue, speaker recognition, and meeting capture. Cloud transcription, web intake, and app-specific live captions are not implemented here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open Activity") { actions.openActivity(); state.destination = .queue }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 850, alignment: .leading)
        }
    }

    private func settingsCard<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
    }

    private func emptyState(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(18)
    }

    private func replaceAll() {
        guard !state.searchText.isEmpty else { return }
        for index in state.segments.indices {
            state.editSegment(at: index, text: state.segments[index].text.replacingOccurrences(of: state.searchText, with: state.replaceText, options: .caseInsensitive))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func timestamp(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d.%03d", (ms / 60_000) % 60, (ms / 1_000) % 60, ms % 1_000)
    }
}

@MainActor
final class WorkspacePlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1

    private var player: AVPlayer?
    private var observer: Any?
    private var currentPath: String?

    func load(path: String?) {
        guard currentPath != path else { return }
        if let observer, let player { player.removeTimeObserver(observer) }
        player?.pause()
        player = nil
        observer = nil
        currentPath = path
        currentTime = 0
        duration = 0
        isPlaying = false
        guard let path else { return }

        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        Task { [weak self] in
            let loadedDuration = try? await item.asset.load(.duration).seconds
            DispatchQueue.main.async {
                guard let self, self.currentPath == path,
                      let loadedDuration, loadedDuration.isFinite, loadedDuration > 0 else { return }
                self.duration = loadedDuration
            }
        }
        observer = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let value = time.seconds
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentPath == path else { return }
                if value.isFinite { self.currentTime = value }
                if let itemDuration = self.player?.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.isPlaying = self.player?.timeControlStatus == .playing
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() }
        else { player.playImmediately(atRate: rate) }
        isPlaying = player.timeControlStatus == .playing
    }

    func play() {
        player?.playImmediately(atRate: rate)
        isPlaying = true
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        let bounded = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = bounded
    }

    func setRate(_ value: Float) {
        rate = value
        if isPlaying { player?.rate = value }
    }
}

private struct SpeakerDirectoryEntry: Identifiable {
    let name: String
    let transcriptCount: Int
    var id: String { name }
}
