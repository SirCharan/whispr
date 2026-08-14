# Changelog

Notable changes to OpenWispr (formerly Whispr), newest first.

## [0.17.2] - 2026-08-14
- Short chunks keep their single words: a two-second "Bye." or "You?" is real speech; lone-word filler is dropped only from chunks longer than 8 seconds.
- `--selftest` no longer crashes after tuning `meetingSpeechFloor` via `defaults write`.
- Meetings log how many chunks fell below the speech floor, so a too-tight floor is visible without Console spelunking.

## [0.17.1] - 2026-08-14
- Whisper's "Thank you." / "Gracias." filler on near-silent meeting audio is now dropped instead of inserted as a transcript line.
- The meeting speech floor is tunable via `defaults write org.openwispr.app meetingSpeechFloor`, calibrated from a real meeting recording.

## [0.17.0] - 2026-08-11
- Fixed meeting mic capture: AVAudioConverter was silently zeroing the 3-channel built-in mic.
- Meeting audio now survives longer: dead system-audio streams restart, capture health shows in the UI, and audio is retained for review.
- Meeting transcription is serialized and decoding is tuned for choppier remote speech.
- Large-v3 is now offered for Indic languages, and the app learns from your insert/delete corrections.
- Other app audio mutes while you're dictating, with a restore you can trust.

## [0.16.1] - 2026-08-06
- Tap-to-dictate now toggles a session that stays open until you tap again; holding past half a second still gives classic push-to-talk.
- Removed the hands-free mode that left taps with no feedback.
- The idle and recording pills now follow the screen under your mouse and re-anchor on Space or display changes.
- Paste's clipboard restore waits 1.5s and backs off if a newer paste already claimed the clipboard.

## [0.16.0] - 2026-08-05
- Reworked onboarding: a personalize step, and a welcome-back flow for people reinstalling.
- Insights now survive reinstalls (stored in Application Support instead of app-local storage).
- Removed the on-device Apple Intelligence cleanup path; BYOK cleanup (Ollama/OpenAI) is unaffected.

## [0.15.0] - 2026-08-04
- First-run wizard cut from 12 steps to 7, in three phases: Permissions, Model, Dictate.
- Live mic level and Accessibility permission now share one screen; meeting-capture setup moved to secondary.
- Speech-model download starts earlier, overlapping with the permissions step.
- Trigger choice, press-test, launch-at-login, and smart cleanup consolidated onto one screen.
- Practice dictation gets a stronger result card.

## [0.14.0] - 2026-07-29
- Added an Insights pane: speaking-pace dial, corrections you've taught the app, lifetime words and hours saved vs. typing, a words-per-day chart, per-app usage, and a streak heatmap.
- Stats now use lifetime counters, so totals survive history trimming and Clear history.

## [0.13.1] - 2026-07-29
- Each transcript row in Dictations now has a copy button; hovering a row and clicking it copies that transcript.

## [0.13.0] - 2026-07-28
- Smart cleanup can now run grammar/formatting rewrites and meeting summaries through Apple's on-device model, free and offline, on macOS 26 with Apple Intelligence — falling back to your BYOK provider otherwise.

## [0.12.0] - 2026-07-28
- Onboarding redesigned around a Permissions → Set up → Try it → Done stepper, with a live mic test and a hotkey press-test.
- If the speech model fails to load, a Reload button now appears instead of the app silently doing nothing.
- Failures are now surfaced honestly: dropped meeting audio, launch-at-login errors, and missing Ollama/API-key setup all explain themselves.

## [0.11.0] - 2026-07-27
- Meeting transcripts are cleaner: Apple's echo cancellation now runs on the mic so the other speaker's audio no longer bleeds into your lines, and duplicate echo lines are dropped.
- Added a per-meeting language picker (vs. Auto, which could garble mixed-language calls).
- Repeated-word hallucination loops in transcripts are now collapsed.

## [0.10.4] - 2026-07-27
- Added the "medium" Whisper model as the best on-shelf choice for Hindi (or any language) to English translation.

## [0.10.3] - 2026-07-27
- Dictionary rows are now editable in place, with inline save/cancel and delete.

## [0.10.2] - 2026-07-27
- The app now appears in the Dock and Cmd-Tab while a window is open, and returns to menu-bar-only once closed.

## [0.10.1] - 2026-07-27
- Fixed Screen Recording permission not being grantable after the app's rename; the meeting pane now registers OpenWispr correctly in System Settings.

## [0.10.0] - 2026-07-26
- Meeting transcripts now separate remote speakers into Speaker A/B on-device, with post-call labeling, disk checkpointing after every line, and pause/resume.

## [0.9.0] - 2026-07-25
- Fixing a word right where you pasted it now triggers the add-to-dictionary prompt, watched for 3 minutes after each dictation.

## [0.8.3] - 2026-07-25
- The floating mic pill moved to the bottom-left corner.

## [0.8.2] - 2026-07-25
- Added a floating mic pill for one-click dictation, toggleable in Settings.

## [0.8.1] - 2026-07-25
- Clicking the app in Applications now opens its home window.

## [0.8.0] - 2026-07-25
- Correcting a transcript now offers to learn the spelling via a one-click prompt, including edits made directly in the app.

## [0.7.1] - 2026-07-25
- Fixed double-pasting from two running copies: the app is now single-instance and shuts down legacy instances automatically.

## [0.7.0] - 2026-07-24
- Rebranded from Whispr to OpenWispr with a new Paper Studio design language across app, site, and onboarding. Existing data migrates automatically.

## [0.6.1] - 2026-07-24
- Added a "Type as" setting for non-English speech: Roman-letter transliteration or full English translation.
