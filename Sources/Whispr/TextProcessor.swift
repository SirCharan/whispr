import Foundation

/// Pure-Swift cleanup applied to the raw transcript before it is pasted.
/// Whisper already punctuates, so our value-add is filler removal + capitalization/spacing normalization.
enum TextProcessor {
    struct Options {
        var removeFillers: Bool
        var cleanUp: Bool // capitalize sentences + collapse whitespace + fix standalone "i"
    }

    private static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mmm", "uhm"]

    static func process(_ text: String, options: Options) -> String {
        var out = text
        if options.removeFillers { out = removeFillers(out) }
        if options.cleanUp { out = cleanUp(out) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeFillers(_ text: String) -> String {
        let kept = text.split(separator: " ", omittingEmptySubsequences: true).filter { word in
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            return !fillers.contains(bare)
        }
        return kept.joined(separator: " ")
    }

    private static func cleanUp(_ text: String) -> String {
        // collapse runs of whitespace, drop space before punctuation
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([.,!?;:])", with: "$1", options: .regularExpression)
        s = fixStandaloneI(s)
        s = capitalizeSentences(s)
        return s
    }

    /// Capitalize the first letter and the first letter after ., !, or ?.
    private static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" { capitalizeNext = true }
            }
        }
        return result
    }

    /// Uppercase the standalone pronoun "i" → "I".
    private static func fixStandaloneI(_ text: String) -> String {
        text.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
    }

    /// Collapse Whisper hallucination loops: the same word 3+ times in a row → one occurrence.
    /// Deliberate doubles ("no no") are preserved. Used on meeting chunks only.
    static func collapseRepeats(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            var j = i
            while j < words.count, words[j].lowercased() == words[i].lowercased() { j += 1 }
            out.append(contentsOf: (j - i) >= 3 ? [words[i]] : Array(words[i..<j]))
            i = j
        }
        return out.joined(separator: " ")
    }

    /// Whole-line Whisper null-output, as opposed to something anyone said.
    ///
    /// Given ~30 s of near-silence or muffled speaker bleed, Whisper does not return an empty
    /// string — it returns the most common phrase in its training data. The 11 Aug 2026 meeting
    /// collected 16 of these on the mic stream alone, all inside chunks that were genuinely loud
    /// with the *remote* participant's voice leaking through the laptop speakers. A level gate
    /// cannot catch those: the chunk has energy, ck simply is not talking.
    ///
    /// Matching is whole-line only, after stripping punctuation. A line that merely *contains*
    /// "thank you" is real speech and is kept. Meetings only — in dictation "Thank you." is a
    /// legitimate thing to say, and deleting it would be the worse failure.
    static func isHallucinatedFiller(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // Punctuation-only lines (".", "-", "- -", "...") carry nothing.
        guard !normalized.isEmpty else { return true }

        // Longest first, so "thank you very much" is stripped before "thank you".
        let fillers = [
            ["subtitles", "by", "the", "amara", "org", "community"],
            ["thanks", "for", "watching"], ["thank", "you", "for", "watching"],
            ["thank", "you", "very", "much"], ["muchas", "gracias"],
            ["please", "subscribe"], ["thank", "you"],
            ["gracias"], ["thanks"], ["bye"], ["goodbye"], ["you"],
        ]
        // Repeatedly peel a filler phrase off the front. "Thank you. Thank you." reduces to
        // nothing and is filler; "Thank you Ravi" leaves "ravi" and is kept.
        var rest = normalized[...]
        outer: while !rest.isEmpty {
            for f in fillers where rest.starts(with: f) {
                rest = rest.dropFirst(f.count)
                continue outer
            }
            return false
        }
        return true
    }

    /// Driven by `core/fixtures/text.json`, the same table the Rust port is held to.
    private struct FixtureFile: Decodable {
        struct ProcessCase: Decodable {
            let input: String
            let removeFillers: Bool
            let cleanUp: Bool
            let expected: String
        }
        struct RepeatCase: Decodable {
            let input: String
            let expected: String
        }
        let process: [ProcessCase]
        let collapseRepeats: [RepeatCase]
    }

    static func selfTest() {
        let f = Fixtures.load(FixtureFile.self, "text.json")
        Fixtures.expect(!f.process.isEmpty, "text.json has no process cases")
        for c in f.process {
            let got = process(c.input, options: Options(removeFillers: c.removeFillers, cleanUp: c.cleanUp))
            Fixtures.expectEqual(got, c.expected, "process(\(c.input))")
        }
        for c in f.collapseRepeats {
            Fixtures.expectEqual(collapseRepeats(c.input), c.expected, "collapseRepeats(\(c.input))")
        }
        // Every one of these `true` cases is a real line from the 11 Aug 2026 meeting transcript.
        // The `false` cases are the ones that must survive: deleting a real line is unrecoverable,
        // a stray "Thank you." is merely untidy, so this filter errs toward keeping.
        let filler = ["Thank you.", "Thank you..", "Thank you. Thank you.", "Gracias.", ".", "-", "- -", "...", "  ", "Bye bye"]
        // Devanagari must survive: ck speaks Hinglish, and `alphanumerics` is Unicode-aware, so
        // these are NOT reduced to an empty token list. A regex over [a-z] would delete them all.
        let keep = ["Thank you Ravi", "Thank you, that answers it", "You are on mute, right?",
                    "So, two, three questions here. Am I audible, first of all?", "Tika.", "Those are many",
                    "भाई चिराग थो जल्दी कर सके हैं आफ टो गो आउट डिनर टाइम",
                    "जो लोग जमीन से जूड़ी होते हैं वोग बहुत कामी मूब करते हैं",
                    "तो मुझे अभी 25,000 ले बागी पर बाद मैं कर लियो",
                    "谢谢大家", "ありがとう"]
        for t in filler {
            Fixtures.expect(isHallucinatedFiller(t), "should be filler: \"\(t)\"")
        }
        for t in keep {
            Fixtures.expect(!isHallucinatedFiller(t), "should be kept: \"\(t)\"")
        }
        print("TextProcessor.selfTest PASS (\(f.process.count + f.collapseRepeats.count + filler.count + keep.count) cases)")
    }
}
