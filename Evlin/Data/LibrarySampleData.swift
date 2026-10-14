import SwiftUI

// The Library's layout running on sample data, before the Library Agent
// exists. Nothing here decides anything: the bundles are a fixed, hand-picked
// list of real made-for-kids YouTube videos, and every child starts with the
// same three. Progress lives in memory on this device only, so the parent's
// phone and the kid's device don't share it yet. When the agent is built,
// LibraryStore's reads are what it replaces; the screens stay.

enum LibrarySubject: String, CaseIterable, Identifiable {
    case science, art, math, nature, kitchen, music, reading, calm
    var id: String { rawValue }

    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var icon: String {
        switch self {
        case .science: return "flask.fill"
        case .art: return "paintbrush.pointed.fill"
        case .math: return "number"
        case .nature: return "leaf.fill"
        case .kitchen: return "fork.knife"
        case .music: return "music.note"
        case .reading: return "book.fill"
        case .calm: return "wind"
        }
    }

    var tint: Color {
        switch self {
        case .science: return Color(hex: "1F6FD1")
        case .art: return Color(hex: "FF6B4A")
        case .math: return Color(hex: "6A4BD6")
        case .nature: return Color(hex: "228B57")
        case .kitchen: return Color(hex: "E0475F")
        case .music: return Color(hex: "33388F")
        case .reading: return Color(hex: "F08A24")
        case .calm: return Color(hex: "3D8AA0")
        }
    }
}

struct LibraryLesson: Identifiable, Hashable {
    let youtubeId: String
    let title: String          // the kid-facing title
    let channel: String        // shown as attribution: "<channel> on YouTube"
    let seconds: Int

    var id: String { youtubeId }
    var thumbnailURL: String { "https://i.ytimg.com/vi/\(youtubeId)/hqdefault.jpg" }
    var minutes: Int { max(1, Int((Double(seconds) / 60).rounded())) }
}

struct LibraryBundle: Identifiable, Hashable {
    let id: String
    let name: String
    let subject: LibrarySubject
    let ages: String
    let why: String
    let lessons: [LibraryLesson]
}

enum LibrarySamples {
    // Kurzgesagt – In a Nutshell: the starting shelf. Hand-picked from its
    // older, gentler catalog (no war, drugs, disease scares or existential
    // episodes). Its videos aren't flagged made-for-kids on YouTube, so the
    // backend's hard filter would reject them; a trusted-channel list has to
    // allow them before the Library Agent can.
    static let bundles: [LibraryBundle] = [
        LibraryBundle(id: "k-space", name: "Space is HUGE", subject: .science, ages: "7–12",
                      why: "Planets, giant stars and black holes", lessons: [
            LibraryLesson(youtubeId: "KsF_hdjWJjo", title: "Our home in space", channel: "Kurzgesagt", seconds: 441),
            LibraryLesson(youtubeId: "8nHBGFKLHZQ", title: "A black hole in your pocket?!", channel: "Kurzgesagt", seconds: 218),
            LibraryLesson(youtubeId: "e-P5IFTqB98", title: "How black holes are born", channel: "Kurzgesagt", seconds: 356),
            LibraryLesson(youtubeId: "3mnSDifDSxQ", title: "The biggest star there is", channel: "Kurzgesagt", seconds: 719),
        ]),
        LibraryBundle(id: "k-body", name: "Your body is a superhero", subject: .science, ages: "7–12",
                      why: "The tiny army inside you", lessons: [
            LibraryLesson(youtubeId: "zQGOcOUBi6s", title: "Your immune system vs. bacteria", channel: "Kurzgesagt", seconds: 469),
            LibraryLesson(youtubeId: "VzPD009qTN4", title: "The bacteria that live in you", channel: "Kurzgesagt", seconds: 458),
            LibraryLesson(youtubeId: "cRZOUcpiOxY", title: "Why fever is awesome", channel: "Kurzgesagt", seconds: 668),
        ]),
        LibraryBundle(id: "k-wild", name: "Weird and wild life", subject: .nature, ages: "7–12",
                      why: "Strange creatures and where they live", lessons: [
            LibraryLesson(youtubeId: "B3QTAgHlwEg", title: "Ants with glue guns", channel: "Kurzgesagt", seconds: 463),
            LibraryLesson(youtubeId: "xaQJbozY_Is", title: "What dinosaurs really looked like", channel: "Kurzgesagt", seconds: 593),
            LibraryLesson(youtubeId: "PaErPyEnDvk", title: "Down in the deep sea", channel: "Kurzgesagt", seconds: 680),
            LibraryLesson(youtubeId: "ZSch_NgZpQs", title: "Trees are so weird", channel: "Kurzgesagt", seconds: 687),
        ]),
        LibraryBundle(id: "k-tiny", name: "Tiny things, big ideas", subject: .science, ages: "8–12",
                      why: "Atoms, light and the very beginning", lessons: [
            LibraryLesson(youtubeId: "_lNF3_30lUE", title: "How small is an atom?", channel: "Kurzgesagt", seconds: 298),
            LibraryLesson(youtubeId: "IXxZRZxafEQ", title: "What is light?", channel: "Kurzgesagt", seconds: 279),
            LibraryLesson(youtubeId: "wNDGgL73ihY", title: "The Big Bang", channel: "Kurzgesagt", seconds: 355),
        ]),
        LibraryBundle(id: "dino", name: "Dino discovery", subject: .science, ages: "5–8",
                      why: "Big creatures, real fossils", lessons: [
            LibraryLesson(youtubeId: "G3gXWDYpLAE", title: "All about dinosaurs", channel: "Happy Learning English", seconds: 307),
            LibraryLesson(youtubeId: "dktnOPfE7Dc", title: "Dinosaurs and fossils", channel: "Learn Bright", seconds: 554),
            LibraryLesson(youtubeId: "qcgq82iBkcw", title: "Velociraptor and friends", channel: "Brain Candy TV", seconds: 558),
        ]),
        LibraryBundle(id: "draw", name: "Draw anything", subject: .art, ages: "4–9",
                      why: "Step-by-step drawing with paper and a pencil", lessons: [
            LibraryLesson(youtubeId: "UW6H5dAPuhY", title: "Draw an ice cream cone", channel: "Art for Kids Hub", seconds: 213),
            LibraryLesson(youtubeId: "2iF-9DAqYu8", title: "Draw a baby axolotl", channel: "Art for Kids Hub", seconds: 294),
            LibraryLesson(youtubeId: "7q3Y6cyE0LI", title: "Draw a teddy bear", channel: "Art for Kids Hub", seconds: 330),
        ]),
        LibraryBundle(id: "ocean", name: "Ocean friends", subject: .nature, ages: "3–7",
                      why: "Sea animals and where they live", lessons: [
            LibraryLesson(youtubeId: "Y4uWm3H7hoo", title: "Sea animal names", channel: "Ed bot TV", seconds: 134),
            LibraryLesson(youtubeId: "FqIjHUvFzDA", title: "Ocean creature facts", channel: "Megan's World", seconds: 260),
            LibraryLesson(youtubeId: "hb-Iu3-Fupo", title: "Animals of the shallow sea", channel: "Learn the ABCs with Kaif", seconds: 534),
        ]),
        LibraryBundle(id: "space", name: "Space explorers", subject: .science, ages: "5–9",
                      why: "The sun, the planets and how they move", lessons: [
            LibraryLesson(youtubeId: "mQrlgH97v94", title: "The planet song", channel: "KLT", seconds: 189),
            LibraryLesson(youtubeId: "w36yxLgwUOc", title: "Our solar system", channel: "Peekaboo Kidz", seconds: 262),
            LibraryLesson(youtubeId: "e8YzKyot4Pc", title: "The eight planets", channel: "Learn Bright", seconds: 683),
        ]),
        LibraryBundle(id: "chefs", name: "Little chefs", subject: .kitchen, ages: "6–10",
                      why: "Simple food to make with a grown-up", lessons: [
            LibraryLesson(youtubeId: "zrXWIWlF5_M", title: "Five homework snacks", channel: "WhatsUpMoms", seconds: 431),
            LibraryLesson(youtubeId: "BPFFmCOXe6U", title: "Three easy breakfasts", channel: "WhatsUpMoms", seconds: 402),
            LibraryLesson(youtubeId: "Sq3Pg7QSi8M", title: "Meals kids can cook", channel: "Rach Bennett", seconds: 503),
        ]),
        LibraryBundle(id: "calm", name: "Calm and cozy", subject: .calm, ages: "3–8",
                      why: "Gentle breathing for winding down", lessons: [
            LibraryLesson(youtubeId: "Mwp9Cmgz2cw", title: "Flower breath", channel: "Yoga Guppy", seconds: 190),
            LibraryLesson(youtubeId: "hMBVZ12nMaI", title: "Cactus breathing", channel: "Yoga Guppy", seconds: 197),
            LibraryLesson(youtubeId: "cyvuaL_2avY", title: "Breathe and stretch", channel: "Moovlee", seconds: 240),
        ]),
        LibraryBundle(id: "count", name: "Counting fun", subject: .math, ages: "3–6",
                      why: "Counting songs, from 20 up to 100", lessons: [
            LibraryLesson(youtubeId: "S84fcGdEULk", title: "Count up to 20", channel: "Super Simple Songs", seconds: 153),
            LibraryLesson(youtubeId: "OXGaGttahxY", title: "Count to 50", channel: "Gracie's Corner", seconds: 200),
            LibraryLesson(youtubeId: "bGetqbqDVaA", title: "Count to 100", channel: "The Singing Walrus", seconds: 239),
        ]),
        LibraryBundle(id: "letters", name: "Letters and sounds", subject: .reading, ages: "3–6",
                      why: "Letter sounds for early reading", lessons: [
            LibraryLesson(youtubeId: "Q0TqoUSUjO0", title: "Letter sounds with moves", channel: "Mrs. Peters' Class", seconds: 137),
            LibraryLesson(youtubeId: "ChqnN3cKzXQ", title: "A to Z phonics chant", channel: "Tora the Teacher", seconds: 263),
            LibraryLesson(youtubeId: "tKsIi1MH4lw", title: "Phonics song", channel: "Rock 'N Learn", seconds: 295),
        ]),
        LibraryBundle(id: "music", name: "Music makers", subject: .music, ages: "4–9",
                      why: "What instruments sound like", lessons: [
            LibraryLesson(youtubeId: "vjJcGlQraek", title: "How instruments sound", channel: "Happy Sunshine Friends", seconds: 215),
            LibraryLesson(youtubeId: "3ogepZsCnbY", title: "27 instruments", channel: "Happy Sunshine Friends", seconds: 262),
            LibraryLesson(youtubeId: "Tde91GvEHV8", title: "Wind, string and drums", channel: "Smile and Learn", seconds: 530),
        ]),
    ]

    static let startingShelf = ["k-space", "k-body", "k-wild"]

    static func bundle(_ id: String) -> LibraryBundle? { bundles.first { $0.id == id } }
}

/// Each child's three bundles and how far they've got. In memory, on this
/// device, until the Library Agent and its tables exist.
@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private var shelves: [String: [String]] = [:]
    private var progress: [String: Int] = [:]          // "child|bundle" → lessons finished
    private var doneToday: Set<String> = []            // "child|bundle"

    private func key(_ childId: String, _ bundleId: String) -> String { "\(childId)|\(bundleId)" }

    func shelf(_ childId: String) -> [LibraryBundle] {
        (shelves[childId] ?? LibrarySamples.startingShelf).compactMap(LibrarySamples.bundle)
    }

    /// Bundles not on this child's shelf, optionally one subject only.
    func alternatives(_ childId: String, subject: LibrarySubject?) -> [LibraryBundle] {
        let on = Set(shelf(childId).map(\.id))
        return LibrarySamples.bundles.filter { !on.contains($0.id) && (subject == nil || $0.subject == subject) }
    }

    func finishedCount(_ childId: String, _ bundle: LibraryBundle) -> Int {
        min(progress[key(childId, bundle.id)] ?? 0, bundle.lessons.count)
    }

    /// The lesson up today: the first one not finished. The last lesson once
    /// the bundle is done, so the card still has something to show.
    func todayLesson(_ childId: String, _ bundle: LibraryBundle) -> LibraryLesson {
        bundle.lessons[min(finishedCount(childId, bundle), bundle.lessons.count - 1)]
    }

    func isFinished(_ childId: String, _ bundle: LibraryBundle) -> Bool {
        finishedCount(childId, bundle) >= bundle.lessons.count
    }

    func isDoneToday(_ childId: String, _ bundle: LibraryBundle) -> Bool {
        doneToday.contains(key(childId, bundle.id))
    }

    /// One lesson per bundle per day: finishing today's advances the bundle.
    func finishToday(_ childId: String, _ bundle: LibraryBundle) {
        let k = key(childId, bundle.id)
        guard !doneToday.contains(k), !isFinished(childId, bundle) else { return }
        progress[k] = finishedCount(childId, bundle) + 1
        doneToday.insert(k)
    }

    func swap(_ childId: String, remove: String, add: String) {
        var ids = shelf(childId).map(\.id)
        guard let i = ids.firstIndex(of: remove) else { return }
        ids[i] = add
        shelves[childId] = ids
    }
}
