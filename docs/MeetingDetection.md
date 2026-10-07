# Meeting detection and automatic capture

## Research

Reviewed October 3, 2026:

- [pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber), including its `MicInputDetector.swift` and `MeetingDetector.swift`: uses process-attributed Core Audio microphone activity and consecutive observations. Its design also distinguishes microphone and window detection strategies.
- [Minutes issue 330](https://github.com/silverstein/minutes/issues/330): documents why generic microphone activity plus an idle Zoom app causes false detections, and why non-default input devices need process attribution.
- [Recall Desktop SDK](https://docs.recall.ai/docs/desktop-sdk), [FAQ](https://docs.recall.ai/docs/desktop-recording-sdk-faq): uses meeting events and operating-system accessibility information. Its documented visibility and platform limitations show why app presence alone is insufficient.
- Apple SDK `AudioHardware.h` and [Core Audio input activity](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput): the process object reports active input streams; bundle IDs identify their owners.
- [Microsoft Teams meeting controls](https://support.microsoft.com/en-US/teams/meetings/use-meeting-controls-in-microsoft-teams) and [Google Meet screen-reader controls](https://support.google.com/meet/answer/15738543?hl=en): checked current English control wording, including Teams’ redesigned Mic control.
- [Apple AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement): read-only call-control inspection requires Accessibility access.

This implementation uses native APIs and independently written detection logic. It does not add a commercial SDK, cloud upload, browser extension, or code copied from the researched projects.

## Behavior

The app must be running. Desktop opening reminders support macOS 13+. Automatic capture and process-attributed microphone detection require macOS 14.2+.

- **Manual:** detection is disabled.
- **Remind me (default):** selected native calling apps and meeting websites show a small, nonactivating banner near the top-right corner. Native openings need no microphone activity, Accessibility permission, or active call. The banner says the app *opened*, not that a meeting has begun. Start recording uses the existing recording/transcription flow; Dismiss and Snooze do not record anything.
- **Auto start:** retains the existing six-second confirmation rule for Zoom, Teams, and Google Meet. App openings alone never start capture. Other platforms are reminders only, including when Auto start is selected. Auto start needs a downloaded meeting model and configured recordings folder; incomplete setup falls back to a reminder.

Native launch reminders use `NSWorkspace.didLaunchApplicationNotification` and `didActivateApplicationNotification`, with a running-application list observer to catch background/LSUIElement launches that do not post launch notifications. The same process receives only one reminder, even if both events fire or the user repeatedly switches back to it. `didTerminateApplicationNotification` clears its opening. Apps already running when the transcriber starts are eligible on their first subsequent activation; background apps are not announced in a burst at startup. Exact primary application bundle IDs exclude helper processes. The FaceTime bundle identifier was verified from the installed system app's Info.plist.

Website opening reminders check URLs in exposed browser documents or the committed window document URL, independently of call controls. They cover the providers listed below. Zoom marketing/support pages and arbitrary pages mentioning video calls do not qualify. Opening a landing page and then joining a call counts as one reminder for that platform/browser. Brief tab switches retain suppression; a new visit can remind after two minutes without exposed website evidence. Website detection requires Accessibility access, and inactive tabs may not be exposed. URLs and query secrets are not retained in opening identities. The scan checks the foreground app first and rotates other eligible apps so a busy browser cannot permanently starve another platform.

## Platform coverage

| Platform | Native app opening | Website opening | Automatic capture |
| --- | --- | --- | --- |
| Zoom | Built in | Meeting invitation and web-client URLs | Confirmed English call UI only |
| Microsoft Teams | Classic and new Teams built in | teams.microsoft.com, teams.live.com, teams.cloud.microsoft | Confirmed English call UI only |
| Google Meet | Its installed web app uses browser URL inspection | meet.google.com, including the homepage | Confirmed English call UI only |
| FaceTime | Built in | facetime.apple.com/join | No |
| Slack | Built in | app.slack.com/client or /huddle | No |
| Discord | Stable, Canary and PTB built in | discord.com/channels and Canary/PTB | No |
| WhatsApp | Built in | web.whatsapp.com | No |
| Telegram, WeChat | Built in | Add an exact site host if needed | No |
| Webex | Select installed app with Add another app | web.webex.com and Webex join/room URLs | No |
| Jitsi Meet | Select installed client with Add another app | meet.jit.si; add private hosts separately | No |
| Whereby | Select a wrapper with Add another app | whereby.com rooms and room subdomains | No |
| RingCentral Video | Select installed app with Add another app | v.ringcentral.com | No |
| GoTo Meeting | Select installed app with Add another app | meet.goto.com | No |
| Signal, other native calling apps | Select installed app with Add another app | Add an exact host if applicable | No |
| Private, embedded or unlisted meeting websites | Select installed wrapper if applicable | Add meeting website, exact host only | No |

Native identities for Teams, Slack, Discord, WhatsApp, Telegram and WeChat were checked against the installed app bundles. An added app uses its actual bundle identifier, not a name heuristic. An added website uses an exact HTTPS hostname; credentials, ports and invalid hosts are rejected. Different added websites keep separate reminder identities; clearing added sources removes their pending reminders. Selecting an ordinary browser as a native added app is rejected: add the meeting site instead.

Supported browser identities include Chrome, Edge, Brave, Safari, Arc, Firefox, Opera, Comet, Quetta, DuckDuckGo and Zen. Chrome/Edge/Brave app bundles and Safari web-app bundles are eligible for URL inspection. Eligibility is not proof that every browser version exposes usable URLs. A window with no accessible committed URL cannot be identified safely; permissions, browser accessibility implementations, hidden/inactive tabs and web-app wrappers can all limit this. Another browser or a selected native wrapper is the fallback. Unknown browser bundle IDs currently require a code registry update; they are not guessed from app names.

Opening a chat app is deliberately treated as an opening, even if the user only plans to send messages. Automatic recording on those openings would be unreliable, so the added platforms do not support it. This is a Mac feature; applications running solely on a phone, another computer or a remote desktop are outside the local app watcher. Every possible provider/version cannot be guaranteed without testing its accessible UI.

Provider references: [Google Meet PWA](https://support.google.com/meet/answer/10708569?hl=en), [Teams Mac client identity](https://learn.microsoft.com/en-us/microsoftteams/teams-client-bulk-install), [Slack huddles](https://slack.com/help/articles/4402059015315-Use-huddles-in-Slack), [Webex guest web client](https://help.webex.com/article/49769d/Webex-App-Join-meeting-as-a-guest), [Webex personal-room links](https://help.webex.com/en-us/article/nqx2ohdb), [Jitsi hosting](https://jitsi.github.io/handbook/), [Whereby room URLs](https://docs.whereby.com/reference/using-the-whereby-embed-element), [RingCentral join URLs](https://developers.ringcentral.com/guide/basics/uri-schemes), and [GoTo meeting network domains](https://support.goto.com/nl/webinar/help/optimal-firewall-configuration-g2w060025).

Opening reminders are queued while transcription or notes generation is busy. During a recording they are consumed rather than deferred until Stop. Snooze pauses opening and call reminders for ten minutes. Once an opening reminder has been shown, stronger call evidence for that platform does not create a second reminder in Remind me mode. Opening suppression is separate from automatic-call tracking so dismissing an app-open reminder does not weaken the auto-start confidence requirement.

A confirmed UI has an actionable Leave / End call control and an actionable microphone control. Plain page text is ignored. Controls currently match English labels. Browser detection checks the exposed document URL; it does not read browser history or inactive tabs. Neither microphone metadata nor UI inspection requests recording permissions. Accessibility is requested only from the settings button. Recording itself retains the existing microphone/system-audio permission flow.

Capture is revalidated after model loading. Stale evidence, a mode change, revoked Accessibility access, or disabled platform cancels automatic capture before audio streams start. Startup failures are reported without a repeating retry loop. The menu bar turns red while recording; Stop remains available. System-audio recording continues to include other audio playing on the Mac, as the existing capture implementation does.

Dismiss and Stop suppress that detected call session. Snooze postpones all detection prompts/start attempts for ten minutes. A session rearms after thirty seconds without evidence. This grace period absorbs reconnects but can suppress an immediately consecutive call on the same native platform. Detection never stops an ongoing recording: use Stop manually. Muting, silence, hiding a window, and changing tabs do not stop capture.

## Limits and verification

UI inspection is bounded and runs on a background queue. Snapshots record which browser/process scopes were fully inspected. A skipped or incomplete scan does not close an existing opening or reset its suppression; fresh confirmation still expires after five seconds, so skipped scans cannot refresh automatic-recording eligibility. Confirmed absence, process termination, and revoked Accessibility retire actionable evidence. Inaccessible, hidden, untranslated, or changed call controls fail closed for automatic capture. Native microphone reminders can still appear for microphone tests or waiting rooms; these are explicitly labeled possible meetings. A muted call may not produce microphone evidence, but can be confirmed through accessible call controls. Browser controls may only be exposed for the currently displayed tab. Multiple simultaneous calls share the existing single recording session.

`tests/MeetingDetectionTests.swift` covers URL/provider boundaries, actionable-control matching, confirmation timing, weak-to-strong upgrades, stale evidence, dismissal, reconnect grace, snooze expiration, duplicate helpers, and manual-stop suppression. These deterministic checks do not replace end-to-end checks with current Zoom, Teams, and Meet versions. Validate actual calls, muted calls, waiting rooms, non-default microphones, background windows, and permissions before relying on unattended recording.

The detection regressions also exercise repeated live metadata snapshots. `tests/MeetingCaptureStartupSmoke.swift` loads the real meeting worker with a rejecting final capture gate and checks that capture never becomes active, saves no audio files, and shuts down cleanly. It is included with `./tests/run-regressions.sh --real-model`.

## Opening-reminder refinement

[Apple launch notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didlaunchapplicationnotification) and [activation notifications](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification) were checked for the native app watcher. Tests cover helper exclusion, launch/activation deduplication, close/reopen, cross-app snoozing, pending-opening suppression during recording, homepage-to-call deduplication, deceptive URL hosts, secret-free identities, tab-switch suppression, and website rearming. Website reminders remain unverified in a real browser with Accessibility granted.

Meeting Settings includes **Preview reminder**. A sample preview disables recording and snoozing; if a real reminder is already open, the button brings that reminder forward. The settings status shows the last app-opening reminder for troubleshooting.

On October 3, 2026, native UI checks verified actual Zoom, Microsoft Teams and FaceTime opening reminders, the banner layout and controls, dismissal, and suppression when returning to the same app. A separately generated local app verified the Add another app chooser, persistence, launch reminder with the selected app's name, and clearing added sources. The test source was removed from preferences afterward. No call was joined and no recording started. The Zoom startup check exposed stale running-application notifications; the observer now reconciles the live application list on the main queue and checks process termination before retiring an opening. The expanded build and full regression suite passed, including 152 detection checks. Browser reminders still need real UI verification after the approved Accessibility setting is authenticated through macOS.
