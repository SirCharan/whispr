import AppKit

/// Learn-from-corrections (Wispr/Muesli pattern, opt-in prompt, never silent):
/// after a paste, watch the clipboard for ~60s. If the user copies an edited version
/// of the transcript, diff word-by-word and offer near-miss corrections for the dictionary.
@MainActor
final class CorrectionsWatcher {
    private var lastTranscript: String?
    private var deadline = Date.distantPast
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func notePaste(_ transcript: String) {
        lastTranscript = transcript
        deadline = Date().addingTimeInterval(180)
        lastChangeCount = NSPasteboard.general.changeCount
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    private func poll() {
        guard Date() < deadline, let transcript = lastTranscript else {
            timer?.invalidate(); timer = nil
            return
        }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let copied = pb.string(forType: .string) else { return }

        let pairs = Self.corrections(original: transcript, edited: copied)
        guard !pairs.isEmpty else { return }
        offer(pairs)
        lastTranscript = nil // one offer per dictation
    }

    private func offer(_ pairs: [(from: String, to: String)]) {
        CorrectionToast.shared.show(pairs) // floating one-click prompt; never steals focus
    }

    /// Pure diff core: aligned word pairs that look like spelling fixes rather than content edits.
    ///
    /// Word counts no longer have to match. The old equal-count gate meant a single added or
    /// deleted word anywhere in the sentence threw away every correction in that edit, including
    /// a real spelling fix at the other end of it. Alignment is LCS over words; only a balanced
    /// replacement run (n words out, n words in) yields candidates, because a pure insertion or
    /// deletion teaches nothing about spelling.
    static func corrections(original: String, edited: String,
                            isRealWord: (String) -> Bool = DictionaryStore.defaultIsRealWord) -> [(from: String, to: String)] {
        let a = original.split(separator: " ").map(String.init)
        let b = edited.split(separator: " ").map(String.init)
        guard a.count > 1, !b.isEmpty else { return [] }
        // whole-string sanity: must be mostly the same text
        guard DictionaryStore.jaroWinkler(original.lowercased(), edited.lowercased()) > 0.85 else { return [] }
        // ponytail: O(n*m) LCS is fine for a dictation-length transcript; bail on anything huge
        // rather than carrying a smarter diff we would never exercise.
        guard a.count * b.count <= 40_000 else { return [] }

        var out: [(String, String)] = []
        let trim = CharacterSet(charactersIn: ".,!?;:\"'()")
        for (wa, wb) in Self.alignedPairs(a, b) {
            let ca = wa.trimmingCharacters(in: trim), cb = wb.trimmingCharacters(in: trim)
            guard ca != cb, ca.count >= 3, cb.count >= 3 else { continue }
            if DictionaryStore.isSpellingFix(ca, cb, isRealWord: isRealWord) { out.append((ca, cb)) }
        }
        return Array(out.prefix(3)) // don't spam
    }

    /// Word pairs that occupy the same slot once both sides are LCS-aligned. Unbalanced runs
    /// (pure inserts or deletes) contribute nothing.
    static func alignedPairs(_ a: [String], _ b: [String]) -> [(String, String)] {
        // lcs[i][j] = length of the longest common subsequence of a[i...] and b[j...]
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if a.count > 0 && b.count > 0 {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1
                                             : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var pairs: [(String, String)] = []
        var removed: [String] = []
        var added: [String] = []

        func flushRun() {
            if removed.count == added.count {
                pairs.append(contentsOf: zip(removed, added).map { ($0, $1) })
            }
            removed.removeAll(); added.removeAll()
        }

        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                flushRun()
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(a[i]); i += 1
            } else {
                added.append(b[j]); j += 1
            }
        }
        while i < a.count { removed.append(a[i]); i += 1 }
        while j < b.count { added.append(b[j]); j += 1 }
        flushRun()
        return pairs
    }

    static func selfTest() {
        let english: Set<String> = ["notes", "not", "able", "add", "words", "the", "cluster",
                                    "today", "deploy", "flying", "to", "tomorrow", "hello", "world"]
        let stub: (String) -> Bool = { english.contains($0.lowercased()) }

        let pairs = corrections(
            original: "deploy the kubernetis cluster today",
            edited: "deploy the Kubernetes cluster today",
            isRealWord: stub
        )
        precondition(pairs.count == 1 && pairs[0].to == "Kubernetes", "correction diff failed: \(pairs)")
        let none = corrections(original: "hello world foo", edited: "completely different text", isRealWord: stub)
        precondition(none.isEmpty, "should reject dissimilar texts")
        let same = corrections(original: "same text here", edited: "same text here", isRealWord: stub)
        precondition(same.isEmpty, "identical texts should yield nothing")
        let caseOnly = corrections(original: "flying to delhi tomorrow", edited: "flying to Delhi tomorrow", isRealWord: stub)
        precondition(caseOnly.count == 1 && caseOnly[0].to == "Delhi", "case-only fix should count: \(caseOnly)")
        // The poisoning case: editing "not" to "notes" is a content change, never a spelling fix.
        let content = corrections(original: "i am not able to add words",
                                  edited: "i am notes able to add words", isRealWord: stub)
        precondition(content.isEmpty, "must not learn ordinary English words: \(content)")

        // Word-count changes used to discard the whole edit. A spelling fix must survive an
        // insertion or a deletion elsewhere in the same sentence.
        let withInsert = corrections(original: "deploy the kubernetis cluster",
                                     edited: "deploy the Kubernetes cluster today", isRealWord: stub)
        precondition(withInsert.count == 1 && withInsert[0].to == "Kubernetes",
                     "fix must survive an inserted word: \(withInsert)")
        let withDelete = corrections(original: "deploy the kubernetis cluster today",
                                     edited: "deploy the Kubernetes cluster", isRealWord: stub)
        precondition(withDelete.count == 1 && withDelete[0].to == "Kubernetes",
                     "fix must survive a deleted word: \(withDelete)")
        // A pure insertion teaches nothing about spelling.
        let pureInsert = corrections(original: "deploy the cluster",
                                     edited: "deploy the cluster today", isRealWord: stub)
        precondition(pureInsert.isEmpty, "pure insertion should yield nothing: \(pureInsert)")

        // Alignment unit checks, independent of the spelling-fix filter.
        let balanced = alignedPairs(["a", "bee", "c"], ["a", "be", "c"])
        precondition(balanced.count == 1 && balanced[0] == ("bee", "be"), "balanced run: \(balanced)")
        let unbalanced = alignedPairs(["a", "c"], ["a", "b", "c"])
        precondition(unbalanced.isEmpty, "insert-only run must not pair: \(unbalanced)")
        print("CorrectionsWatcher.selfTest PASS")
    }
}
