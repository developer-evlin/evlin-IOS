import Foundation

/// An emoji for a task title, from every emoji there is, on the phone.
///
/// The index is Unicode's own English names and keywords for each emoji
/// (CLDR annotations, Resources/emoji-keywords.json, ~1,600 emoji), so
/// "Brush teeth" finds 🪥 because CLDR lists "brush" and "teeth" for it.
/// A small synonym table covers chores whose words aren't in CLDR
/// ("dishwasher", "homework"). Instant and offline. An emoji picked by the
/// chat agent or by the parent always wins over this guess (tasks.icon).
enum EmojiSuggest {
    /// Used when nothing matches.
    static let fallback = "⭐"

    /// The best emoji for `title`, then alternatives, at most `limit`;
    /// `[fallback]` when nothing matches.
    static func suggestions(for title: String, limit: Int = 4) -> [String] {
        let tokens = title.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { !stopWords.contains($0) }
        var score: [String: Double] = [:]
        for token in tokens {
            let stemmed = stem(token)
            // The word itself, its stem, then its synonyms (slightly
            // favoured: they're picked by hand for exactly this).
            var words: [(String, Double)] = [(token, 1.0)]
            if stemmed != token { words.append((stemmed, 0.9)) }
            for s in (synonyms[token] ?? []) + (synonyms[stemmed] ?? []) { words.append((s, 1.2)) }
            var best: [String: Double] = [:]
            for (word, factor) in words {
                for (emoji, weight) in index[word] ?? [:] {
                    best[emoji] = max(best[emoji] ?? 0, weight * factor)
                }
            }
            for (emoji, value) in best { score[emoji, default: 0] += value }
        }
        // Faces and people only when the title is about them: a chore is
        // better shown by its object than by a face reacting to it.
        for emoji in score.keys where isFaceOrPerson(emoji) { score[emoji]! *= 0.5 }
        let ranked = score.keys.sorted {
            score[$0]! != score[$1]! ? score[$0]! > score[$1]! : (keywordCount[$0] ?? 99) < (keywordCount[$1] ?? 99)
        }
        let picked = ranked.prefix(limit).map(displayForm)
        return picked.isEmpty ? [fallback] : Array(picked)
    }

    static func best(for title: String) -> String { suggestions(for: title, limit: 1)[0] }

    /// A single-scalar emoji whose default look is plain text (🛏, 🍽)
    /// shows as an emoji only with the variation selector after it.
    static func displayForm(_ emoji: String) -> String {
        let scalars = emoji.unicodeScalars
        guard scalars.count == 1, let s = scalars.first, !s.properties.isEmojiPresentation else { return emoji }
        return emoji + "\u{FE0F}"
    }

    // MARK: - Index

    /// word → emoji → weight: 4 for the whole name ("bed"), 3 for a word
    /// of a longer name ("tropical fish"), 2 for a keyword.
    private static let index: [String: [String: Double]] = {
        var idx: [String: [String: Double]] = [:]
        for (emoji, words) in annotations {
            guard let name = words.first else { continue }
            let nameWords = name.split(separator: " ").map(String.init)
            for w in nameWords { idx[w, default: [:]][emoji] = max(idx[w]?[emoji] ?? 0, nameWords.count == 1 ? 4 : 3) }
            for keyword in words.dropFirst() {
                for w in keyword.split(separator: " ").map(String.init) {
                    idx[w, default: [:]][emoji] = max(idx[w]?[emoji] ?? 0, 2)
                }
            }
        }
        return idx
    }()

    /// Fewer keywords = a more specific emoji, which wins a tie.
    private static let keywordCount: [String: Int] = annotations.mapValues(\.count)

    private static let annotations: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "emoji-keywords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded
    }()

    private static func stem(_ w: String) -> String {
        for suffix in ["ing", "es", "s", "ed"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            return String(w.dropLast(suffix.count))
        }
        return w
    }

    private static func isFaceOrPerson(_ emoji: String) -> Bool {
        guard let v = emoji.unicodeScalars.first?.value else { return false }
        return (0x1F600...0x1F64F).contains(v) || (0x1F910...0x1F92F).contains(v) || (0x1F970...0x1F97A).contains(v)
            || (0x1F44A...0x1F450).contains(v) || (0x1F466...0x1F487).contains(v)
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "their", "our", "to", "do", "go", "get", "make", "take",
        "put", "have", "be", "and", "or", "of", "for", "in", "on", "at", "up", "with", "some", "all", "any",
        "this", "that", "it", "its", "time", "out", "off", "away", "before", "after", "every", "day", "minutes",
    ]

    /// Chore words CLDR doesn't list, mapped to words it does.
    private static let synonyms: [String: [String]] = [
        "dishwasher": ["plate", "fork"], "dishes": ["plate", "fork"], "dish": ["plate", "fork"], "table": ["plate"],
        "homework": ["memo", "pencil"], "study": ["books", "book"], "math": ["abacus", "numbers"],
        "laundry": ["basket", "laundry"], "teeth": ["toothbrush", "tooth"], "floss": ["toothbrush"],
        "tidy": ["broom"], "clean": ["broom", "sponge"], "vacuum": ["broom"], "sweep": ["broom"], "mop": ["bucket"],
        "trash": ["wastebasket"], "garbage": ["wastebasket"], "rubbish": ["wastebasket"], "recycle": ["recycling"],
        "room": ["broom"], "desk": ["desk", "broom"], "plant": ["potted", "plant"], "garden": ["seedling"],
        "water": ["potted"], "walk": ["dog", "walking"], "read": ["books"], "shower": ["shower"], "bath": ["bathtub"],
        "cook": ["cooking"], "bake": ["cookie"], "pack": ["backpack"], "bag": ["backpack"], "shoes": ["shoe"],
        "clothes": ["shirt"], "fold": ["shirt"], "car": ["automobile"], "bike": ["bicycle"], "draw": ["artist", "palette"],
        "paint": ["palette"], "write": ["pencil"], "journal": ["notebook"], "exercise": ["running"], "run": ["running"],
        "jog": ["running"], "swim": ["swimming"], "snack": ["apple"], "vegetables": ["broccoli"], "veggies": ["broccoli"],
        "fruit": ["apple"], "hair": ["comb"], "sleep": ["bed"], "nap": ["bed"], "bedtime": ["bed"], "pet": ["paw"],
        "lego": ["brick"], "singing": ["microphone"], "toys": ["teddy"], "toy": ["teddy"], "windows": ["window"],
        "towels": ["towel"], "lawn": ["herb"], "leaves": ["leaf"], "snow": ["snowman"], "mail": ["envelope"],
        "drums": ["drum"], "piano": ["piano", "keyboard"], "chores": ["broom"],
    ]
}
