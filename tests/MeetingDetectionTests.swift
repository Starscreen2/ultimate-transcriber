import Foundation
import AppKit

@main
struct MeetingDetectionTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func main() {
        expect(MeetingPlatform.native(bundleID: "us.zoom.xos") == .zoom, "Zoom bundle")
        expect(MeetingPlatform.native(bundleID: "us.zoom.xos.ZoomHybridConf") == .zoom, "Zoom audio helper")
        expect(MeetingPlatform.native(bundleID: "com.microsoft.teams2") == .teams, "new Teams bundle")
        expect(MeetingPlatform.native(bundleID: "com.microsoft.teams.helper") == .teams, "legacy Teams helper")
        expect(MeetingPlatform.application(bundleID: "com.apple.FaceTime") == .faceTime, "FaceTime opening")
        expect(MeetingPlatform.application(bundleID: "us.zoom.xos.ZoomHybridConf") == nil, "helper launched an opening reminder")
        expect(!MeetingPlatform.faceTime.supportsAutomaticCapture, "FaceTime must remain reminders only")
        for id in ["us.zoom.xos-malicious", "com.microsoft.teamsOther", "com.google.Chrome", "local.transcribetotext.app", "com.apple.VoiceMemos"] {
            expect(MeetingPlatform.native(bundleID: id) == nil, "unrelated microphone owner accepted: \(id)")
        }
        for url in ["https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij?authuser=1"] {
            expect(MeetingPlatform.web(url: url) == .googleMeet, "Meet call URL")
        }
        expect(MeetingPlatform.web(url: "https://teams.microsoft.com/v2/") == .teams, "Teams web")
        expect(MeetingPlatform.web(url: "https://us02web.zoom.us/wc/123/join") == .zoom, "Zoom web")
        for url in ["https://meet.google.com/", "https://meet.google.com/landing", "https://meet.google.com.evil.test/abc-defg-hij",
                    "https://evil.test/meet.google.com/abc-defg-hij", "http://meet.google.com/abc-defg-hij",
                    "https://meet.google.com@evil.test/abc-defg-hij", "https://zoom.us/j/123", "not a URL"] {
            expect(MeetingPlatform.web(url: url) == nil, "non-call URL accepted: \(url)")
        }
        var controls = MeetingCallControls()
        controls.observe(role: "AXStaticText", labels: ["Leave call", "Mute microphone"])
        expect(!controls.isInCall, "page text mistaken for call controls")
        controls.observe(role: "AXButton", labels: ["Leave feedback", "End screen sharing", "Mute notifications"])
        expect(!controls.isInCall, "unrelated buttons mistaken for call controls")
        controls.observe(role: "AXButton", labels: ["Leave call (⌘W)"])
        expect(!controls.isInCall, "exit alone is insufficient")
        controls.observe(role: "AXButton", labels: ["  Unmute   microphone  "])
        expect(controls.isInCall, "muted calls should still be recognized")
        var teams = MeetingCallControls()
        teams.observe(role: "AXButton", labels: ["Leave", "Unmute (Ctrl+Shift+M)"])
        expect(teams.isInCall, "Teams controls with shortcut")
        var redesignedTeams = MeetingCallControls()
        redesignedTeams.observe(role: "AXButton", labels: ["Leave", "Mic"])
        expect(redesignedTeams.isInCall, "Teams redesigned Mic control")

        let possible = MeetingEvidence(key: "native:zoom", platform: .zoom, confirmedCall: false)
        let confirmed = MeetingEvidence(key: possible.key, platform: .zoom, confirmedCall: true)
        var tracker = MeetingDetectionTracker()
        tracker.update([], now: 0)
        expect(tracker.opportunities(now: 100).isEmpty, "app running alone cannot trigger")
        for time in [0.0, 2, 4] { tracker.update([possible], now: time) }
        expect(tracker.opportunities(now: 4).isEmpty, "transient mic use should not trigger")
        tracker.update([possible], now: 6)
        expect(tracker.opportunities(now: 6) == [possible], "stable native mic activity should remind")
        expect(!tracker.canAutoStart(possible.key, now: 6), "unconfirmed microphone use auto-started")
        tracker.update([confirmed], now: 8)
        expect(!tracker.canAutoStart(possible.key, now: 8), "confidence upgrade skipped debounce")
        for time in [10.0, 12, 14] { tracker.update([confirmed], now: time) }
        expect(tracker.canAutoStart(possible.key, now: 14), "stable controls should allow auto start")
        tracker.claim(confirmed.key)
        expect(tracker.opportunities(now: 14).isEmpty, "dismissed/started session repeated")
        expect(tracker.canAutoStart(confirmed.key, now: 14), "claimed session cannot pass final preparation check")
        tracker.update([], now: 16)
        expect(!tracker.canAutoStart(confirmed.key, now: 16), "ended call passed final capture check")
        tracker.update([confirmed], now: 18)
        for time in [20.0, 22, 24] { tracker.update([confirmed], now: time) }
        expect(tracker.opportunities(now: 24).isEmpty, "reconnect re-prompted")
        tracker.update([], now: 26)
        tracker.update([], now: 54)
        for time in [56.0, 58, 60, 62] { tracker.update([confirmed], now: time) }
        expect(tracker.opportunities(now: 62) == [confirmed], "later meeting failed to rearm")
        expect(!tracker.canAutoStart(confirmed.key, now: 68), "stale scan allowed auto start")
        tracker.snooze(confirmed.key, now: 62)
        for time in stride(from: 64.0, through: 660.0, by: 2) { tracker.update([confirmed], now: time) }
        expect(tracker.opportunities(now: 660).isEmpty, "snooze expired too early")
        tracker.update([confirmed], now: 662)
        expect(tracker.opportunities(now: 662) == [confirmed], "snooze did not expire")
        tracker.claimAll()
        tracker.update([possible], now: 664)
        expect(tracker.opportunities(now: 664).isEmpty, "manual stop followed by immediate auto restart")
        expect(!tracker.canAutoStart(confirmed.key, now: 664), "weak downgrade retained confidence")

        var duplicate = MeetingDetectionTracker()
        for time in [0.0, 2, 4, 6] { duplicate.update([possible, confirmed, possible], now: time) }
        expect(duplicate.opportunities(now: 6).count == 1, "audio helpers duplicated session")
        expect(duplicate.canAutoStart(confirmed.key, now: 6), "duplicate weak evidence erased confidence")
        duplicate.update([], now: 8)
        duplicate.update([confirmed], now: 10)
        expect(!duplicate.canAutoStart(confirmed.key, now: 10), "interrupted evidence retained debounce")
        testOpeningReminders()
        testAdditionalPlatforms()
        testPartialScans()
        if MeetingDetector.supported {
            let detector = MeetingDetector()
            var snapshots = 0
            var audioAvailable = false
            detector.start(enabledPlatforms: { Set(MeetingPlatform.allCases) }, isEnabled: { true }, onSnapshot: { sample in
                snapshots += 1
                audioAvailable = audioAvailable || sample.audioMetadataAvailable
            })
            let deadline = Date().addingTimeInterval(6)
            while snapshots < 2 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            detector.stop()
            expect(snapshots >= 2, "live detector failed to deliver repeated snapshots")
            print("Live detection snapshot check: Core Audio metadata \(audioAvailable ? "available" : "unavailable (UI-only fallback)").")
        }
        print("Meeting detection regressions passed (\(checks) checks).")
    }

    static func testOpeningReminders() {
        let zoom = MeetingOpening.application(platform: .zoom, pid: 100)
        let teams = MeetingOpening.application(platform: .teams, pid: 200)
        var tracker = MeetingOpeningTracker()
        tracker.opened(zoom, now: 0)
        expect(tracker.opportunities(now: 0) == [zoom], "launch reminder depended on microphone or call controls")
        tracker.claim(zoom.key)
        tracker.opened(zoom, now: 1)
        tracker.opened(zoom, now: 100)
        expect(tracker.opportunities(now: 100).isEmpty, "launch and activation produced duplicate reminders")
        expect(tracker.hasReminded(.zoom), "stronger call evidence should not duplicate the opening reminder")
        tracker.opened(teams, now: 101)
        expect(tracker.opportunities(now: 101) == [teams], "opening another platform should have its own reminder")
        tracker.claimAll()
        expect(tracker.opportunities(now: 102).isEmpty, "recording should consume queued openings")
        tracker.closed(zoom.key)
        expect(!tracker.isPresent(zoom.key), "closed app retained a start action")
        let reopened = MeetingOpening.application(platform: .zoom, pid: 101)
        tracker.opened(reopened, now: 103)
        expect(tracker.opportunities(now: 103) == [reopened], "reopened app did not rearm")
        tracker.claim(reopened.key)
        tracker.snooze(reopened.key, now: 103)
        let faceTime = MeetingOpening.application(platform: .faceTime, pid: 300)
        tracker.opened(faceTime, now: 104)
        expect(tracker.opportunities(now: 702).isEmpty, "snooze did not cover other app openings")
        expect(tracker.opportunities(now: 703).count == 2, "snooze did not expire for pending open apps")

        let meet = MeetingOpening.website(url: "https://meet.google.com/", pid: 400)!
        let meetCall = MeetingOpening.website(url: "https://meet.google.com/abc-defg-hij?authuser=1", pid: 400)!
        expect(meet == meetCall, "home page followed by joining a call should be one reminder")
        expect(MeetingOpening.website(url: "https://teams.microsoft.com/", pid: 400)?.platform == .teams, "Teams website opening")
        expect(MeetingOpening.website(url: "https://zoom.us/j/123?pwd=secret", pid: 400)?.platform == .zoom, "Zoom invitation opening")
        expect(!MeetingOpening.website(url: "https://zoom.us/j/123?pwd=secret", pid: 400)!.key.contains("secret"), "opening identity retained URL secrets")
        for url in ["https://meet.google.com.evil.test/", "https://evil.test/meet.google.com/", "http://meet.google.com/",
                    "https://user@meet.google.com/", "https://zoom.us/", "https://support.zoom.us/j/1234"] {
            // Zoom subdomains are accepted for meeting links, so a support host has to
            // be separately excluded from the meeting website matcher.
            expect(MeetingOpening.website(url: url, pid: 400) == nil, "unrelated website opened a reminder: \(url)")
        }
        var web = MeetingOpeningTracker()
        web.updateWebsites([meet], now: 0)
        expect(web.opportunities(now: 0) == [meet], "Meet homepage required an active call")
        web.claim(meet.key)
        web.updateWebsites([meetCall], now: 2)
        expect(web.opportunities(now: 2).isEmpty, "joining the call repeated the reminder")
        web.updateWebsites([], now: 4)
        expect(!web.isPresent(meet.key), "hidden website retained an actionable prompt")
        web.updateWebsites([meetCall], now: 6)
        expect(web.opportunities(now: 6).isEmpty, "tab switching repeated the reminder")
        web.updateWebsites([], now: 8)
        web.updateWebsites([], now: 126)
        web.updateWebsites([meet], now: 128)
        expect(web.opportunities(now: 128) == [meet], "later website visit did not rearm")
    }

    static func testAdditionalPlatforms() {
        let native: [(String, MeetingPlatform)] = [
            ("com.tinyspeck.slackmacgap", .slack), ("com.hnc.Discord", .discord),
            ("net.whatsapp.WhatsApp", .whatsApp), ("ru.keepcoder.Telegram", .telegram),
            ("com.tencent.xinWeChat", .weChat)
        ]
        for (id, platform) in native {
            expect(MeetingPlatform.application(bundleID: id) == platform, "primary app opening missing: \(id)")
            expect(MeetingPlatform.application(bundleID: id + ".helper") == nil, "helper opening accepted: \(id)")
            expect(!platform.supportsAutomaticCapture, "unverified platform allowed unattended capture")
        }
        let websites: [(String, MeetingPlatform)] = [
            ("https://web.webex.com/", .webex), ("https://company.webex.com/meet/person", .webex),
            ("https://company.webex.com/wbxmjs/joinservice/sites/company/meeting/123", .webex),
            ("https://meet.jit.si/", .jitsi), ("https://whereby.com/my-room", .whereby),
            ("https://company.whereby.com/my-room", .whereby), ("https://v.ringcentral.com/join/123", .ringCentral),
            ("https://meet.goto.com/123", .goTo), ("https://app.slack.com/client/T123/C456", .slack),
            ("https://discord.com/channels/@me", .discord), ("https://web.whatsapp.com/", .whatsApp)
        ]
        for (url, platform) in websites {
            expect(MeetingOpening.website(url: url, pid: 42)?.platform == platform, "website reminder missing: \(url)")
            expect(MeetingPlatform.web(url: url) == nil, "new reminder provider became an automatic call detector")
            expect(MeetingOpening.website(url: url.replacingOccurrences(of: "https://", with: "http://"), pid: 42) == nil, "insecure website accepted")
        }
        for url in ["https://help.webex.com/meet/person", "https://www.webex.com/", "https://whereby.com/blog/news",
                    "https://docs.whereby.com/reference", "https://whereby.com/pricing", "https://discord.com/",
                    "https://app.slack.com.evil.test/client/T/C", "https://web.whatsapp.com.evil.test/",
                    "https://meet.jit.si.evil.test/room", "https://facetime.apple.com/join-marketing"] {
            expect(MeetingOpening.website(url: url, pid: 42) == nil, "marketing/deceptive URL accepted: \(url)")
        }
        for id in ["com.operasoftware.Opera", "ai.perplexity.comet", "app.zen-browser.zen", "com.google.Chrome.app.abcdef",
                   "com.apple.Safari.WebApp.abcdef"] {
            expect(MeetingPlatform.isBrowser(bundleID: id), "browser or installed web app omitted")
        }
        expect(!MeetingPlatform.isBrowser(bundleID: "com.google.Chrome.helper"), "browser helper accepted")
        let added = MeetingAdditionalSources.application(bundleID: "org.example.Calling", pid: 1, applications: ["org.example.Calling": "My calls"])!
        expect(added.title == "My calls" && added.platform == .other, "selected app title lost")
        expect(MeetingAdditionalSources.application(bundleID: "org.example.Calling.helper", pid: 2, applications: ["org.example.Calling": "My calls"]) == nil,
               "selected app matched helper or arbitrary prefix")
        expect(MeetingAdditionalSources.websiteHost(" HTTPS://calls.example.org/room?token=secret ") == "calls.example.org", "hostname normalization failed")
        for raw in ["http://calls.example.org", "https://user:secret@calls.example.org", "https://calls.example.org:1234",
                    "not a hostname", "https://example..org", "example", "https://example.org@evil.test",
                    "calls.-example.org", "calls.example-.org", "calls._example.org", String(repeating: "a", count: 64) + ".org"] {
            expect(MeetingAdditionalSources.websiteHost(raw) == nil, "invalid custom hostname accepted")
        }
        let overridden = MeetingOpening.website(url: "https://meet.google.com/home", pid: 42, additionalHosts: ["meet.google.com"])!
        expect(overridden.platform == .other && overridden.title == "meet.google.com", "explicit site ignored its Added sites toggle")
        let custom = MeetingOpening.website(url: "https://calls.example.org/room?secret=value", pid: 42, additionalHosts: ["calls.example.org"])!
        expect(custom.title == "calls.example.org" && !custom.key.contains("secret"), "custom website leaked URL data")
        expect(MeetingOpening.website(url: "https://calls.example.org.evil.test/", pid: 42, additionalHosts: ["calls.example.org"]) == nil, "custom hostname suffix attack")
        expect(MeetingOpening.website(url: "https://other.example.org/", pid: 42, additionalHosts: ["calls.example.org"]) == nil, "custom host matched unrelated site")
        var tracker = MeetingOpeningTracker()
        tracker.opened(added, now: 0)
        tracker.opened(custom, now: 1)
        tracker.opened(.application(platform: .zoom, pid: 3), now: 2)
        tracker.clearAdditionalSources()
        expect(tracker.opportunities(now: 3).count == 1, "removing added sources affected built-in reminders")
    }
    static func testPartialScans() {
        let meet = MeetingOpening.website(url: "https://meet.google.com/home", pid: 400)!
        let skipped = MeetingScanCoverage(runningScopes: ["web:400", "native:zoom"], completedScopes: [])
        let inspected = MeetingScanCoverage(runningScopes: skipped.runningScopes, completedScopes: skipped.runningScopes)
        let terminated = MeetingScanCoverage(runningScopes: [], completedScopes: [])
        var openings = MeetingOpeningTracker()
        openings.updateWebsites([meet], now: 0, coverage: inspected)
        openings.claim(meet.key)
        openings.updateWebsites([], now: 2, coverage: skipped)
        expect(openings.isPresent(meet.key), "skipped browser scan closed an existing reminder")
        openings.updateWebsites([], now: 130, coverage: skipped)
        openings.updateWebsites([meet], now: 132, coverage: inspected)
        expect(openings.opportunities(now: 132).isEmpty, "scan interruption or sleep repeated a claimed reminder")
        openings.updateWebsites([], now: 134, coverage: inspected)
        expect(!openings.isPresent(meet.key), "fully observed absence retained an actionable opening")
        openings.updateWebsites([meet], now: 254, coverage: inspected)
        expect(openings.opportunities(now: 254) == [meet], "known absence did not rearm after the grace period")
        openings.updateWebsites([], now: 256, coverage: terminated)
        expect(!openings.isPresent(meet.key), "terminated browser retained a start action")

        let call = MeetingEvidence(key: "web:400:meet.google.com/abc-defg-hij", platform: .googleMeet, confirmedCall: true)
        var tracker = MeetingDetectionTracker()
        for time in [0.0, 2, 4] { tracker.update([call], now: time, coverage: inspected) }
        tracker.update([], now: 6, coverage: skipped)
        expect(tracker.canAutoStart(call.key, now: 6), "skipped scan reset continuous call confirmation")
        expect(!tracker.canAutoStart(call.key, now: 10), "skipped scan refreshed stale confirmation")
        tracker.update([call], now: 8, coverage: inspected)
        tracker.claim(call.key)
        tracker.update([], now: 40, coverage: skipped)
        for time in [42.0, 44, 46, 48] { tracker.update([call], now: time, coverage: inspected) }
        expect(tracker.canAutoStart(call.key, now: 48), "confirmation did not recover after skipped scans")
        expect(tracker.opportunities(now: 48).isEmpty, "unscanned claimed call rearmed")
        tracker.update([], now: 50, coverage: inspected)
        expect(!tracker.canAutoStart(call.key, now: 50), "observed call ending retained automatic capture")
        tracker.update([call], now: 52, coverage: inspected)
        tracker.update([], now: 54, coverage: terminated)
        expect(!tracker.isPresent(call.key, now: 54), "terminated browser retained call evidence")

        let native = MeetingEvidence(key: "native:zoom", platform: .zoom, confirmedCall: true)
        let microphoneOnly = MeetingEvidence(key: native.key, platform: .zoom, confirmedCall: false)
        var nativeTracker = MeetingDetectionTracker()
        for time in [0.0, 2, 4] { nativeTracker.update([native], now: time, coverage: inspected) }
        nativeTracker.update([microphoneOnly], now: 6, coverage: skipped)
        expect(nativeTracker.canAutoStart(native.key, now: 6), "unscanned microphone metadata downgraded confirmed controls")
        nativeTracker.update([microphoneOnly], now: 10, coverage: skipped)
        expect(!nativeTracker.canAutoStart(native.key, now: 10), "microphone-only metadata refreshed confirmed controls")
        nativeTracker.update([microphoneOnly], now: 12, coverage: inspected)
        expect(!nativeTracker.canAutoStart(native.key, now: 12), "inspected weak evidence retained confidence")
    }

}
