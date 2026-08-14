# Roadmap

Updated 2026-08-14, after the v0.17.x meeting-capture rebuild. Ordering reflects user value per unit of work for a solo maintainer. Nothing here is a commitment.

## 1. Meeting quality

The v0.17.x rebuild fixed the capture layer (dead mic, dropped chunks, hallucinated filler). The remaining quality gap is segmentation and timing.

1. **Silero VAD segmentation.** Replace the energy-based pause heuristic with FluidAudio `VadManager`. Cuts chunks at real speech boundaries, so quiet remote speech stops competing with room tone. Add per-stream gain normalization (EMA) so one floor fits both streams. Decision and config recorded; fallback is fixed 15 s segments with 1 s overlap.
2. **One shared clock.** Derive timestamps from `CMSampleBuffer` presentation time instead of sample counts. Today the mic and system streams drift apart over a long meeting, and a dropout compresses out of the timeline.
3. **Stream-failure hardening.** Fix three known bugs: `AudioRecorder.start` leaks its tap when `engine.start()` throws; `resume()` leaves the mic running when the system stream fails to start; after eight failed restarts a meeting keeps running mic-only with no banner. A dead stream must be loud in the UI, not a quiet room.
4. **Audio playback in meeting history.** The raw WAVs are already retained. A play button per meeting lets you check whether a bad transcript was a bad recording or a bad model. Cheapest trust feature available.
5. **Named speakers that persist.** The rename sheet exists per meeting. Store voice embeddings so "Speaker A" becomes "Ravi" in the next meeting too.
6. **Echo dedup, re-enabled behind evidence.** Cross-stream dedup is off because it deleted real mic lines. It stays off until logs show AEC keeps speaker bleed out of the mic stream.
7. **Live transcript view.** Lines already arrive incrementally; show them during the meeting instead of only at the end.

## 2. Dictation and app features

Informed by what Wispr Flow and Muesli ship. OpenWispr stays fully on-device for transcription; AI features stay bring-your-own-key.

| Feature | Why | Effort |
|---|---|---|
| Export meeting as Markdown / PDF | Transcripts are already Markdown internally; unlocks sharing | Low |
| Cleanup tiers (None / Light / Medium / High) + per-app tone | One toggle today; Wispr Flow's tiering is the right shape | Low |
| MCP server over transcript history | Lets Claude/Cursor query your meetings; small surface, developer audience | Low |
| Calendar awareness: detect a meeting, offer one-click record | Removes the "forgot to hit record" failure; Muesli's headline feature | Medium |
| Parakeet ASR backend option | Muesli defaults to it; lower latency than Whisper on Apple Silicon | Medium |
| Command mode: select text, hold trigger, speak an instruction | Wispr Flow's most-cited differentiator; we have the BYOK layer already | Medium |
| Context-aware dictation (read the field, match tone) | Needs accessibility text reads; do after command mode | Medium |
| Streaming dictation preview (true streaming ASR) | Current preview re-transcribes the whole buffer | High |

## 3. Not planned

- **Cross-meeting "Ask Anything" search.** Needs embeddings infrastructure; the MCP server gets most of the value by delegating to a model that already has it.
- **Whisper/subvocal mode, team features, leaderboards.** Different product.
- **Cloud transcription.** On-device is the point.

## Done recently

- v0.17.1 — hallucinated-filler gate, tunable speech floor measured from a real meeting.
- v0.17.0 — 3-channel mic fix, FIFO transcription, WAV retention, stream health + auto-restart, mute-on-dictate, Indic large-v3, correction learning.
- v0.16.1 — hybrid tap/hold trigger, pills follow the active screen.
