import AppKit
import ApplicationServices
import CoreAudio

// Detection observes call UI and Core Audio metadata; it never captures audio.
enum MeetingDetectionMode: String, CaseIterable {
    case manual, remind, automatic
    var title: String {
        switch self {
        case .manual: return "Manual"
        case .remind: return "Remind me"
        case .automatic: return "Auto start recording and transcription"
        }
    }
}

enum MeetingPlatform: String, CaseIterable {
    case zoom, teams, googleMeet, faceTime, slack, discord, whatsApp, telegram, weChat
    case webex, jitsi, whereby, ringCentral, goTo, other
    var title: String {
        switch self {
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .googleMeet: return "Google Meet"
        case .faceTime: return "FaceTime"
        case .slack: return "Slack"
        case .discord: return "Discord"
        case .whatsApp: return "WhatsApp"
        case .telegram: return "Telegram"
        case .weChat: return "WeChat"
        case .webex: return "Webex"
        case .jitsi: return "Jitsi Meet"
        case .whereby: return "Whereby"
        case .ringCentral: return "RingCentral"
        case .goTo: return "GoTo Meeting"
        case .other: return "Added apps / sites"
        }
    }

    var supportsAutomaticCapture: Bool { [.zoom, .teams, .googleMeet].contains(self) }

    // Only actual application bundles produce opening reminders; helpers do not.
    static func application(bundleID: String) -> MeetingPlatform? {
        switch bundleID.lowercased() {
        case "us.zoom.xos": return .zoom
        case "com.microsoft.teams", "com.microsoft.teams2": return .teams
        case "com.apple.facetime": return .faceTime
        case "com.tinyspeck.slackmacgap": return .slack
        case "com.hnc.discord", "com.hnc.discordcanary", "com.hnc.discordptb": return .discord
        case "net.whatsapp.whatsapp": return .whatsApp
        case "ru.keepcoder.telegram": return .telegram
        case "com.tencent.xinwechat": return .weChat
        default: return nil
        }
    }

    static func native(bundleID: String) -> MeetingPlatform? {
        let id = bundleID.lowercased()
        if id == "us.zoom.xos" || id.hasPrefix("us.zoom.xos.") { return .zoom }
        if ["com.microsoft.teams", "com.microsoft.teams2"].contains(id) ||
            id.hasPrefix("com.microsoft.teams.") || id.hasPrefix("com.microsoft.teams2.") { return .teams }
        if id == "com.apple.facetime" { return .faceTime }
        return nil
    }

    static func web(url: String) -> MeetingPlatform? {
        guard let components = URLComponents(string: url), components.scheme == "https",
              components.user == nil, let host = components.host?.lowercased() else { return nil }
        let path = components.path.lowercased()
        if host == "meet.google.com",
           path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$", options: .regularExpression) != nil { return .googleMeet }
        if (host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft"),
           path != "/", !path.isEmpty { return .teams }
        if (host == "zoom.us" || host.hasSuffix(".zoom.us")), path.hasPrefix("/wc/") { return .zoom }
        return nil
    }

    static func isBrowser(bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        let browsers = ["com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary", "com.microsoft.edgemac",
                        "com.brave.browser", "com.apple.safari", "company.thebrowser.browser", "org.mozilla.firefox",
                        "com.operasoftware.opera", "ai.perplexity.comet", "net.quetta.browser.desktop",
                        "com.duckduckgo.mobile.ios", "app.zen-browser.zen"]
        return browsers.contains(id) || ["com.google.chrome.app.", "com.microsoft.edgemac.app.",
                                        "com.brave.browser.app.", "com.apple.safari.webapp."].contains { id.hasPrefix($0) }
    }

    static func reminderWebsite(url: String) -> MeetingPlatform? {
        guard let components = URLComponents(string: url), components.scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return nil }
        if host == "meet.google.com" { return .googleMeet }
        if ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host) { return .teams }
        if (host == "zoom.us" || host.hasSuffix(".zoom.us")),
           !["support.zoom.us", "explore.zoom.us", "developers.zoom.us", "marketplace.zoom.us"].contains(host) {
            let path = components.path.lowercased()
            if ["/j/", "/wc/", "/my/", "/s/"].contains(where: { path.hasPrefix($0) }) { return .zoom }
        }
        let path = components.path.lowercased()
        if host == "facetime.apple.com", path == "/join" || path.hasPrefix("/join/") { return .faceTime }
        if host == "app.slack.com", path.hasPrefix("/client/") || path.hasPrefix("/huddle/") { return .slack }
        if ["discord.com", "canary.discord.com", "ptb.discord.com"].contains(host), path.hasPrefix("/channels/") { return .discord }
        if host == "web.whatsapp.com" { return .whatsApp }
        if host == "web.webex.com" { return .webex }
        if host.hasSuffix(".webex.com"), !["help.webex.com", "developer.webex.com", "www.webex.com"].contains(host),
           ["/meet/", "/join/", "/wbxmjs/", "/webappng/", "/webapp/"].contains(where: { path.hasPrefix($0) }) { return .webex }
        if host == "meet.jit.si" { return .jitsi }
        if host == "whereby.com" || host.hasSuffix(".whereby.com"),
           !["docs.whereby.com", "www.whereby.com"].contains(host),
           path != "", path != "/", !["/blog", "/information", "/pricing", "/business", "/embed", "/user"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .whereby }
        if host == "v.ringcentral.com" { return .ringCentral }
        if host == "meet.goto.com" { return .goTo }
        return nil
    }
}

// Explicitly selected app bundles and exact website hosts extend reminders without
// guessing from app names, window titles, or microphone activity.
enum MeetingAdditionalSources {
    static func application(bundleID: String, pid: pid_t, applications: [String: String]) -> MeetingOpening? {
        if let platform = MeetingPlatform.application(bundleID: bundleID) { return .application(platform: platform, pid: pid) }
        guard let name = applications[bundleID], !name.isEmpty else { return nil }
        return MeetingOpening(key: "opened-app:\(pid):other:\(bundleID)", platform: .other, isWebsite: false, displayName: name)
    }

    static func websiteHost(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), host.contains("."),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  $0.count <= 63 && $0.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", options: .regularExpression) != nil
              }), host.count <= 253 else { return nil }
        return host
    }
}

struct MeetingOpening: Equatable {
    let key: String
    let platform: MeetingPlatform
    let isWebsite: Bool
    var displayName: String? = nil
    var title: String { displayName ?? platform.title }
    static func application(platform: MeetingPlatform, pid: pid_t) -> MeetingOpening {
        MeetingOpening(key: "opened-app:\(pid):\(platform.rawValue)", platform: platform, isWebsite: false)
    }
    static func website(url: String, pid: pid_t, additionalHosts: Set<String> = []) -> MeetingOpening? {
        // An explicitly added host has its own toggle, even when a built-in
        // provider is disabled. Respect that exact-host configuration first.
        guard let components = URLComponents(string: url), components.scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased() else { return nil }
        if additionalHosts.contains(host) {
            return MeetingOpening(key: "opened-web:\(pid):other:\(host)", platform: .other, isWebsite: true, displayName: host)
        }
        guard let platform = MeetingPlatform.reminderWebsite(url: url) else { return nil }
        // A landing page followed by a call URL is one opening, not two reminders.
        return MeetingOpening(key: "opened-web:\(pid):\(platform.rawValue)", platform: platform, isWebsite: true)
    }
}

struct MeetingOpeningTracker {
    private struct Entry {
        let opening: MeetingOpening
        var lastSeen: TimeInterval
        var present = true
        var claimed = false
    }
    private var entries: [String: Entry] = [:]
    private var snoozedUntil: TimeInterval = 0
    static let websiteAbsenceGrace: TimeInterval = 120

    mutating func opened(_ opening: MeetingOpening, now: TimeInterval) {
        if var existing = entries[opening.key] {
            existing.present = true
            existing.lastSeen = now
            entries[opening.key] = existing
        } else {
            entries[opening.key] = Entry(opening: opening, lastSeen: now)
        }
    }

    mutating func closed(_ key: String) { entries.removeValue(forKey: key) }
    mutating func clearAdditionalSources() { entries = entries.filter { $0.value.opening.platform != .other } }

    mutating func updateWebsites(_ openings: [MeetingOpening], now: TimeInterval, coverage: MeetingScanCoverage? = nil) {
        let keys = Set(openings.map(\.key))
        for key in Array(entries.keys) {
            guard var entry = entries[key], entry.opening.isWebsite else { continue }
            if !entry.present, now - entry.lastSeen >= Self.websiteAbsenceGrace {
                entries.removeValue(forKey: key)
                continue
            }
            guard !keys.contains(key), coverage?.canConfirmAbsence(key) != false else { continue }
            if now - entry.lastSeen >= Self.websiteAbsenceGrace {
                entries.removeValue(forKey: key)
            } else {
                entry.present = false
                entries[key] = entry
            }
        }
        for opening in openings { opened(opening, now: now) }
    }

    func opportunities(now: TimeInterval) -> [MeetingOpening] {
        guard now >= snoozedUntil else { return [] }
        return entries.values.filter { $0.present && !$0.claimed }.sorted { $0.lastSeen < $1.lastSeen }.map(\.opening)
    }
    func isPresent(_ key: String) -> Bool { entries[key]?.present == true }
    func hasReminded(_ platform: MeetingPlatform) -> Bool {
        entries.values.contains { $0.opening.platform == platform && $0.claimed }
    }
    mutating func claim(_ key: String) { entries[key]?.claimed = true }
    mutating func claimAll() { for key in entries.keys { entries[key]?.claimed = true } }
    mutating func snooze(_ key: String, now: TimeInterval) {
        entries[key]?.claimed = false
        snoozedUntil = now + 600
    }
}

struct MeetingEvidence: Equatable {
    let key: String
    let platform: MeetingPlatform
    let confirmedCall: Bool
}

// Exact controls with optional keyboard shortcuts, not arbitrary text containing "leave".
struct MeetingCallControls {
    var hasExit = false
    var hasMicrophone = false
    var isInCall: Bool { hasExit && hasMicrophone }

    mutating func observe(role: String, labels: [String]) {
        guard ["AXButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(role) else { return }
        for value in labels {
            let label = value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if Self.matches(label, phrases: ["leave", "leave meeting", "leave call", "end", "end meeting", "end call", "hang up"]) {
                hasExit = true
            }
            if Self.matches(label, phrases: ["mic", "microphone", "mute", "unmute", "mute audio", "unmute audio", "mute my audio", "unmute my audio", "mute microphone", "unmute microphone",
                                              "turn on microphone", "turn off microphone", "microphone on", "microphone off"]) {
                hasMicrophone = true
            }
        }
    }

    private static func matches(_ label: String, phrases: [String]) -> Bool {
        phrases.contains { label == $0 || label.hasPrefix($0 + " (") || label.hasPrefix($0 + ",") }
    }
}

// Pure state machine so timing, suppression, and confidence can be tested without a real call.
struct MeetingDetectionTracker {
    private struct Entry {
        var evidence: MeetingEvidence
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var confirmedSince: TimeInterval?
        var present = true
        var claimed = false
    }
    private var entries: [String: Entry] = [:]
    private(set) var snoozedUntil: TimeInterval = 0
    static let confirmationDelay: TimeInterval = 6
    static let disappearanceGrace: TimeInterval = 30

    mutating func update(_ evidence: [MeetingEvidence], now: TimeInterval, coverage: MeetingScanCoverage? = nil) {
        // One platform can have multiple audio helper processes. The collector deduplicates
        // them; prefer confirmed evidence if a caller supplies duplicates anyway.
        let observed = evidence.filter { signal in
            // A skipped UI scan must not downgrade a previously confirmed call
            // to microphone-only evidence or refresh its last confirmation time.
            signal.confirmedCall || entries[signal.key]?.evidence.confirmedCall != true ||
                coverage?.canConfirmAbsence(signal.key) != false
        }
        let current = Dictionary(observed.map { ($0.key, $0) }, uniquingKeysWith: { $1.confirmedCall ? $1 : $0 })
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            if !entry.present, now - entry.lastSeen >= Self.disappearanceGrace { entries.removeValue(forKey: key); continue }
            if current[key] == nil, coverage?.canConfirmAbsence(key) != false {
                if now - entry.lastSeen >= Self.disappearanceGrace { entries.removeValue(forKey: key); continue }
                entry.present = false
                entry.confirmedSince = nil
                entries[key] = entry
            }
        }
        for (key, signal) in current {
            if var entry = entries[key] {
                if !entry.present || now - entry.lastSeen > 5 {
                    entry.firstSeen = now
                    entry.confirmedSince = nil
                }
                entry.present = true
                entry.evidence = signal
                entry.lastSeen = now
                entry.confirmedSince = signal.confirmedCall ? (entry.confirmedSince ?? now) : nil
                entries[key] = entry
            } else {
                entries[key] = Entry(evidence: signal, firstSeen: now, lastSeen: now,
                                     confirmedSince: signal.confirmedCall ? now : nil)
            }
        }
    }

    func opportunities(now: TimeInterval) -> [MeetingEvidence] {
        guard now >= snoozedUntil else { return [] }
        return entries.values.filter {
            $0.present && !$0.claimed && now - $0.lastSeen <= 5 && now - $0.firstSeen >= Self.confirmationDelay
        }.map(\.evidence).sorted {
            if $0.confirmedCall != $1.confirmedCall { return $0.confirmedCall }
            return $0.key < $1.key
        }
    }

    func canAutoStart(_ key: String, now: TimeInterval) -> Bool {
        guard now >= snoozedUntil, let entry = entries[key], entry.present,
              now - entry.lastSeen <= 5, let confirmedSince = entry.confirmedSince else { return false }
        return now - confirmedSince >= Self.confirmationDelay
    }

    func isPresent(_ key: String, now: TimeInterval) -> Bool {
        guard let entry = entries[key] else { return false }
        return entry.present && now - entry.lastSeen <= 5
    }

    mutating func claim(_ key: String) { entries[key]?.claimed = true }
    mutating func claimAll() { for key in entries.keys { entries[key]?.claimed = true } }
    mutating func snooze(_ key: String, now: TimeInterval) {
        entries[key]?.claimed = false
        snoozedUntil = now + 600
    }
}

// Coverage separates an observed absence from an app skipped by the AX budget.
// Web reminder and call keys share a browser process scope; native call keys
// share a platform scope because a call may live in a helper process.
struct MeetingScanCoverage {
    let runningScopes: Set<String>
    let completedScopes: Set<String>

    static func scope(for key: String) -> String {
        let parts = key.split(separator: ":")
        if parts.count >= 2, parts[0] == "web" || parts[0] == "opened-web" { return "web:\(parts[1])" }
        return key
    }
    func canConfirmAbsence(_ key: String) -> Bool {
        let scope = Self.scope(for: key)
        return !runningScopes.contains(scope) || completedScopes.contains(scope)
    }
}

struct MeetingDetectionSnapshot {
    let evidence: [MeetingEvidence]
    var openedWebsites: [MeetingOpening] = []
    let audioMetadataAvailable: Bool
    let accessibilityAvailable: Bool
    var coverage: MeetingScanCoverage? = nil
}

final class MeetingDetector {
    static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }
    static var accessibilityAvailable: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private let queue = DispatchQueue(label: "local.transcriber.meeting-detection", qos: .utility)
    private var timer: DispatchSourceTimer?
    // The worker only reads configuration passed from the main thread in each request.
    private var generation = 0
    private var scanInProgress = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservation: NSKeyValueObservation?
    private var knownApplications: [pid_t: MeetingOpening] = [:]
    private var scanOffset = 0

    func start(enabledPlatforms: @escaping () -> Set<MeetingPlatform>,
               isEnabled: @escaping () -> Bool,
               additionalApplications: @escaping () -> [String: String] = { [:] },
               additionalWebsiteHosts: @escaping () -> Set<String> = { [] },
               onAppOpened: @escaping (MeetingOpening) -> Void = { _ in },
               onAppClosed: @escaping (String) -> Void = { _ in },
               onSnapshot: @escaping (MeetingDetectionSnapshot) -> Void) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        // Launch notifications omit LSUIElement/background apps. Observe the running
        // application list too, using an initial baseline to avoid startup reminders.
        func openings(_ apps: [NSRunningApplication]) -> [pid_t: MeetingOpening] {
            Dictionary(apps.compactMap { app -> (pid_t, MeetingOpening)? in
                guard !app.isTerminated, let id = app.bundleIdentifier,
                      let opening = MeetingAdditionalSources.application(bundleID: id, pid: app.processIdentifier,
                                                                         applications: additionalApplications()) else { return nil }
                return (app.processIdentifier, opening)
            }, uniquingKeysWith: { first, _ in first })
        }
        knownApplications = openings(NSWorkspace.shared.runningApplications)
        let observationGeneration = generation
        applicationObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == observationGeneration else { return }
                // Launches can enqueue several list changes before the main queue runs.
                // Reconcile the live list rather than a stale notification payload, and
                // only retire a reminder when its process has actually terminated.
                let current = openings(NSWorkspace.shared.runningApplications)
                for (pid, opening) in self.knownApplications where current[pid] == nil {
                    if NSRunningApplication(processIdentifier: pid)?.isTerminated != false { onAppClosed(opening.key) }
                }
                for (pid, opening) in current where self.knownApplications[pid] == nil {
                    if isEnabled(), enabledPlatforms().contains(opening.platform) { onAppOpened(opening) }
                }
                self.knownApplications = current
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      let opening = MeetingAdditionalSources.application(bundleID: bundleID, pid: app.processIdentifier,
                                                                         applications: additionalApplications()) else { return }
                if name == NSWorkspace.didTerminateApplicationNotification { onAppClosed(opening.key); return }
                guard !app.isTerminated, isEnabled(), enabledPlatforms().contains(opening.platform) else { return }
                onAppOpened(opening)
            })
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            guard let self, !self.scanInProgress, isEnabled() else { return }
            let enabled = enabledPlatforms()
            let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, String)? in
                guard let id = app.bundleIdentifier, !app.isTerminated,
                      MeetingPlatform.isBrowser(bundleID: id) || MeetingPlatform.native(bundleID: id).map({ enabled.contains($0) }) == true else { return nil }
                return (app.processIdentifier, id)
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let background = candidates.filter { $0.0 != frontmost }
            let offset = background.isEmpty ? 0 : self.scanOffset % background.count
            let apps = candidates.filter { $0.0 == frontmost } + Array(background.dropFirst(offset)) + Array(background.prefix(offset))
            self.scanOffset += 1
            let hosts = additionalWebsiteHosts()
            self.scanInProgress = true
            let generation = self.generation
            self.queue.async {
                let snapshot = Self.scan(apps: apps, enabled: enabled, additionalHosts: hosts)
                DispatchQueue.main.async {
                    guard self.generation == generation else { return }
                    self.scanInProgress = false
                    onSnapshot(snapshot)
                }
            }
        }
        timer = source
        source.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        scanInProgress = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        applicationObservation?.invalidate()
        applicationObservation = nil
        knownApplications = [:]
    }

    private static func scan(apps: [(pid_t, String)], enabled: Set<MeetingPlatform>, additionalHosts: Set<String>) -> MeetingDetectionSnapshot {
        let inputs: [(bundleID: String, pid: pid_t)]?
        if #available(macOS 14.2, *) { inputs = activeInputProcesses() } else { inputs = nil }
        let trusted = accessibilityAvailable
        var signals: [String: MeetingEvidence] = [:]
        var websites: [String: MeetingOpening] = [:]
        var runningScopes = Set(apps.compactMap { pid, bundle -> String? in
            if MeetingPlatform.isBrowser(bundleID: bundle) { return "web:\(pid)" }
            return MeetingPlatform.native(bundleID: bundle).map { "native:\($0.rawValue)" }
        })
        // Keep helper-owned calls in scope even if the main app has closed.
        for input in inputs ?? [] {
            if let platform = MeetingPlatform.native(bundleID: input.bundleID) { runningScopes.insert("native:\(platform.rawValue)") }
        }
        var completedScopes = Set<String>()
        var incompleteScopes = Set<String>()
        // Attribute microphone activity to the audio process's own bundle, never to an
        // unrelated app merely because that app happens to be running.
        for input in inputs ?? [] {
            guard let platform = MeetingPlatform.native(bundleID: input.bundleID), enabled.contains(platform) else { continue }
            let key = "native:\(platform.rawValue)"
            signals[key] = MeetingEvidence(key: key, platform: platform, confirmedCall: false)
        }
        if trusted {
            // A total budget keeps an unresponsive app or huge browser document from
            // backing up the polling queue. AX failures produce no confirmed evidence.
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            for (pid, bundle) in apps {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                let native = MeetingPlatform.native(bundleID: bundle)
                let browser = MeetingPlatform.isBrowser(bundleID: bundle)
                guard (native.map { enabled.contains($0) } ?? false) || (browser && !enabled.isEmpty) else { continue }
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.08)
                let appDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.45)
                let scope = browser ? "web:\(pid)" : "native:\(native!.rawValue)"
                guard let windows = value(root, attribute: kAXWindowsAttribute) as? [AXUIElement] else {
                    incompleteScopes.insert(scope)
                    continue
                }
                var complete = windows.count <= 8
                for window in windows.prefix(8) {
                    guard ProcessInfo.processInfo.systemUptime < appDeadline else { complete = false; break }
                    if let platform = native {
                        let result = controls(in: window, deadline: appDeadline)
                        complete = complete && result.complete
                        if result.controls.isInCall {
                            let key = "native:\(platform.rawValue)"
                            signals[key] = MeetingEvidence(key: key, platform: platform, confirmedCall: true)
                        }
                    } else if browser {
                        // Safari and some web-app wrappers expose the committed URL on
                        // the window, even when their WebArea has no AXURL attribute.
                        if let raw = value(window, attribute: kAXDocumentAttribute) as? String,
                           let opening = MeetingOpening.website(url: raw, pid: pid, additionalHosts: additionalHosts),
                           enabled.contains(opening.platform) { websites[opening.key] = opening }
                        let documents = webDocuments(in: window, deadline: appDeadline)
                        complete = complete && documents.complete
                        for document in documents.documents {
                            let rawURL = value(document, attribute: kAXURLAttribute)
                            let documentURL = (rawURL as? URL) ?? (rawURL as? String).flatMap { URL(string: $0) }
                            guard let url = documentURL else { complete = false; continue }
                            if let opening = MeetingOpening.website(url: url.absoluteString, pid: pid, additionalHosts: additionalHosts), enabled.contains(opening.platform) {
                                websites[opening.key] = opening
                            }
                            guard let platform = MeetingPlatform.web(url: url.absoluteString), enabled.contains(platform) else { continue }
                            let result = controls(in: document, deadline: appDeadline)
                            complete = complete && result.complete
                            guard result.controls.isInCall else { continue }
                            // Query parameters may contain secrets; only host/path identify a call.
                            let key = "web:\(pid):\(url.host ?? "")\(url.path)"
                            signals[key] = MeetingEvidence(key: key, platform: platform, confirmedCall: true)
                        }
                    }
                }
                if complete { completedScopes.insert(scope) } else { incompleteScopes.insert(scope) }
            }
        } else {
            // Permission revocation retires actionable UI evidence immediately.
            completedScopes = runningScopes
        }
        completedScopes.subtract(incompleteScopes)
        return MeetingDetectionSnapshot(evidence: Array(signals.values), openedWebsites: Array(websites.values), audioMetadataAvailable: inputs != nil,
                                        accessibilityAvailable: trusted,
                                        coverage: MeetingScanCoverage(runningScopes: runningScopes, completedScopes: completedScopes))
    }

    private static func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func walk(_ root: AXUIElement, deadline: TimeInterval, stop: () -> Bool = { false },
                             visit: (AXUIElement, String) -> Bool) -> Bool {
        var complete = true
        var pending = [root]
        var index = 0
        while index < pending.count && index < 1800 && !stop() && ProcessInfo.processInfo.systemUptime < deadline {
            let element = pending[index]
            index += 1
            guard let role = value(element, attribute: kAXRoleAttribute) as? String else { complete = false; continue }
            if !visit(element, role) { continue }
            var rawChildren: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren)
            if result != .success && result != .attributeUnsupported && result != .noValue { complete = false }
            let children = rawChildren as? [AXUIElement] ?? []
            let limit = max(0, 2200 - pending.count)
            if children.count > limit { complete = false }
            pending.append(contentsOf: children.prefix(limit))
        }
        return complete && index == pending.count && ProcessInfo.processInfo.systemUptime < deadline
    }

    private static func webDocuments(in window: AXUIElement, deadline: TimeInterval) -> (documents: [AXUIElement], complete: Bool) {
        var documents: [AXUIElement] = []
        let complete = walk(window, deadline: deadline) { element, role in
            if role == "AXWebArea" { documents.append(element); return false }
            return true
        }
        return (documents, complete)
    }

    private static func controls(in root: AXUIElement, deadline: TimeInterval) -> (controls: MeetingCallControls, complete: Bool) {
        var controls = MeetingCallControls()
        let complete = walk(root, deadline: deadline, stop: { controls.isInCall }) { element, role in
            if ["AXButton", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(role) {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap {
                    value(element, attribute: $0) as? String
                }
                controls.observe(role: role, labels: labels)
            }
            return true
        }
        return (controls, complete || controls.isInCall)
    }

    @available(macOS 14.2, *)
    private static func activeInputProcesses() -> [(bundleID: String, pid: pid_t)]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let result = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return nil }
        var active: [(String, pid_t)] = []
        for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride) {
            guard scalar(object, selector: kAudioProcessPropertyIsRunningInput) == 1,
                  let pid = scalar(object, selector: kAudioProcessPropertyPID) else { continue }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle)
            // Core Audio's documented caller ownership requires consuming the retained value.
            let id = status == noErr ? bundle?.takeRetainedValue() as String? : nil
            if let id, !id.isEmpty { active.append((id, pid_t(bitPattern: pid))) }
        }
        return active
    }

    private static func scalar(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
