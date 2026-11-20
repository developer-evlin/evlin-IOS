import SwiftUI

/// Something a child works toward: a number of times (or days), and a prize
/// from the parent at the end. The child checks in each time and the parent
/// answers; the check-in that reaches it makes it a milestone.
///
/// Kept on this phone only for now (`GoalStore`): the server has no goals
/// yet, so they don't reach the parent's other phone or the kid's device.
struct Goal: Codable, Identifiable, Equatable {
    var id: String
    var childId: String
    var title: String
    var target: Int
    /// "times", "days", or "streak" (days in a row: a missed day starts it
    /// again).
    var unit: String
    var prize: String
    var done: Int = 0
    var colorIndex: Int = 0
    var createdAt: Date = Date()
    /// When it was reached: from then on it's a milestone.
    var finishedAt: Date? = nil
    /// Whether a check-in takes a photo. Either way the child checks in from
    /// their own Goals tab each time they do it, and the parent answers each
    /// one; the ones that look good are what count. Goals are apart from the
    /// chores that unlock the phone: a check-in never locks or opens anything.
    var needsPhoto: Bool = false
    /// Kept for goals saved before every check-in was approved on its own.
    var approveEachDay: Bool = true
    var entries: [GoalCheckIn] = []
    /// The last day counted by hand, on goals saved when parents did that (a
    /// streak needs it).
    var lastCounted: Date? = nil
    /// The idea it was made from, when the parent renamed it ("Clean the
    /// kitchen" from "Clean the house"): its picture and
    /// icon stay. Nil: the title is the idea.
    var picture: String? = nil

    /// What its picture and icon are looked up by.
    var pictureKey: String { picture ?? title }

    // needsPhoto keeps its saved name: goals saved as `checkIns` load as they were.
    private enum CodingKeys: String, CodingKey {
        case id, childId, title, target, unit, prize, done, colorIndex, createdAt, finishedAt
        case needsPhoto = "checkIns"
        case approveEachDay, entries, lastCounted, picture
    }

    init(id: String, childId: String, title: String, target: Int, unit: String, prize: String,
         done: Int = 0, colorIndex: Int = 0, createdAt: Date = Date(), finishedAt: Date? = nil,
         needsPhoto: Bool = false, approveEachDay: Bool = true, entries: [GoalCheckIn] = []) {
        self.id = id; self.childId = childId; self.title = title; self.target = target; self.unit = unit
        self.prize = prize; self.done = done; self.colorIndex = colorIndex; self.createdAt = createdAt
        self.finishedAt = finishedAt; self.needsPhoto = needsPhoto; self.approveEachDay = approveEachDay
        self.entries = entries
    }

    // Goals saved before check-ins existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        childId = try c.decode(String.self, forKey: .childId)
        title = try c.decode(String.self, forKey: .title)
        target = try c.decode(Int.self, forKey: .target)
        unit = try c.decode(String.self, forKey: .unit)
        prize = try c.decode(String.self, forKey: .prize)
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        needsPhoto = try c.decodeIfPresent(Bool.self, forKey: .needsPhoto) ?? false
        approveEachDay = try c.decodeIfPresent(Bool.self, forKey: .approveEachDay) ?? true
        entries = try c.decodeIfPresent([GoalCheckIn].self, forKey: .entries) ?? []
        lastCounted = try c.decodeIfPresent(Date.self, forKey: .lastCounted)
        picture = try c.decodeIfPresent(String.self, forKey: .picture)
    }

    /// Days in a row: every day, and a missed day starts it again.
    var isStreak: Bool { unit == "streak" }
    /// Counted at most once a day.
    var oncePerDay: Bool { unit == "days" || isStreak }
    /// The unit as words: "times", "days", "days in a row".
    var unitWords: String { Goal.words(unit) }
    static func words(_ unit: String) -> String { unit == "streak" ? "days in a row" : unit }

    /// How many days the child did it, for a reached habit: a habit counted
    /// in days took its target; one counted in times, the days it was
    /// checked in on (else the days from start to finish).
    var daysDone: Int {
        if oncePerDay { return target }
        let cal = Calendar.current
        let days = Set(entries.filter { $0.status == .approved }.map { cal.startOfDay(for: $0.at) }).count
        if days > 0 { return days }
        if let end = finishedAt {
            let span = cal.dateComponents([.day], from: cal.startOfDay(for: createdAt), to: cal.startOfDay(for: end)).day ?? 0
            return max(1, span + 1)
        }
        return target
    }
    /// "8 days", "1 day".
    var daysDoneWords: String { daysDone == 1 ? "1 day" : "\(daysDone) days" }

    /// The last day it was counted: an approved check-in, or by hand long ago.
    var lastDay: Date? {
        (entries.filter { $0.status == .approved }.map(\.at) + [lastCounted].compactMap { $0 }).max()
    }

    /// A streak whose last day is before yesterday has been broken.
    var streakBroken: Bool {
        guard isStreak, !reached, done > 0 else { return false }
        guard let last = lastDay else { return true }
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) else { return false }
        return last < yesterday
    }

    var waiting: [GoalCheckIn] { entries.filter { $0.status == .waiting } }
    /// Today's check-ins still waiting: the only ones the parent answers.
    var waitingToday: [GoalCheckIn] { waiting.filter { Calendar.current.isDateInToday($0.at) } }
    /// A photo waiting: it opens on the full screen. Otherwise, the half card.
    /// Habits take no photos (2026-11-05): every check-in is answered on the
    /// half card, never the photo story.
    var photoWaiting: Bool { false }
    /// Checked in already today (a goal counted in days takes one a day).
    var checkedInToday: Bool { entries.contains { Calendar.current.isDateInToday($0.at) && $0.status != .notApproved } }

    var reached: Bool { done >= target }
    var fraction: Double { target > 0 ? min(1, Double(done) / Double(target)) : 0 }
    /// What's still to do, in words: "13 days left". The kid's side counts
    /// today's check-in as soon as it's sent.
    func leftWords(countingWaiting: Bool = false) -> String {
        let left = max(0, target - done - (countingWaiting ? waitingToday.count : 0))
        let word = unit == "times" ? "time" : "day"
        return "\(left) \(word)\(left == 1 ? "" : "s") left"
    }
    /// The goal's own colour pair: its ring, its milestone card.
    var colors: [Color] { [StatusCardStyle.green, StatusCardStyle.green] }

    /// The icon for the goal: its idea's, or for one the parent typed, one
    /// that fits its words, or a leaf (drawn green in the ring, `HabitLeaf`).
    var symbol: String {
        if picture == Self.leafPicture { return Self.leafSymbol }
        if let idea = GoalIdea.all.first(where: { $0.title == pictureKey }) { return idea.symbol }
        let name = title.lowercased()
        return Self.symbolWords.first { $0.words.contains { name.contains($0) } }?.symbol ?? Self.leafSymbol
    }

    /// A habit with nothing better: a leaf, not a star (2026-11-05).
    static let leafSymbol = "leaf.fill"
    /// `picture` for a habit the parent gave the leaf by hand, in New
    /// habit's picture picker: the leaf, whatever its words.
    static let leafPicture = "leaf"

    private static let symbolWords: [(words: [String], symbol: String)] = [
        (["piano", "guitar", "violin", "music", "sing"], "music.note"),
        (["draw", "paint", "art", "colour", "color"], "paintpalette.fill"),
        (["read", "book"], "book.fill"),
        (["write", "homework", "spell"], "pencil"),
        (["bike", "cycle"], "bicycle"),
        (["swim"], "figure.pool.swim"),
        (["run", "walk", "soccer", "football", "sport"], "figure.run"),
        (["cook", "bake", "dinner", "lunch", "breakfast"], "fork.knife"),
        (["clean", "tidy", "dishes", "chore"], "sparkles"),
        (["plant", "garden"], "leaf.fill"),
        (["dog", "cat", "pet"], "pawprint.fill"),
        (["math", "number", "count"], "number"),
    ]
}

/// One time the child said they did it, and what the parent made of it.
struct GoalCheckIn: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case waiting, approved, notApproved }
    var id: String = UUID().uuidString
    var at: Date
    var note: String? = nil
    var status: Status = .waiting
    /// The proof: a photo, as a file in GoalProof's folder on this device,
    /// or a web address (the Demo app's samples).
    var photo: String? = nil
}

/// Where check-in photos are kept.
enum GoalProof {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GoalProof", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stored reference as a URL to load.
    static func url(_ ref: String) -> URL? {
        if ref.hasPrefix("http") { return URL(string: ref) }
        return folder.appendingPathComponent(ref)
    }

    /// Saves a photo, small, and returns its reference.
    static func save(photo: UIImage) -> String? {
        guard let data = PhotoCompression.compress(photo, maxDimension: 1400) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: folder.appendingPathComponent(name)); return name } catch { return nil }
    }

    /// Recordings left from when goals took them.
    static func removeOldRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["m4a", "wav"].contains(file.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

enum GoalStyle {
    /// Goals sit on pitch black, so they never read as one more task.
    static let ground = Color.black
    static let raised = Color(hex: "141416")
    static let hairline = Color.white.opacity(0.12)
    static let soft = Color.white.opacity(0.6)
    static let ok = Color(hex: "7CE29A")
    static let warn = Color(hex: "FFC56E")
}

/// After a goal's reached: New habit for the child, or this one again.
struct NextHabit: Identifiable {
    let id = UUID()
    var childId: String
    var again: Goal?
}

/// Every child's goals, saved on this phone.
@MainActor
final class GoalStore: ObservableObject {
    static let shared = GoalStore()

    @Published private(set) var goals: [Goal] = []
    /// A goal that's just become a milestone, for its moment on screen
    /// (`MilestoneCelebrationWatcher`).
    @Published var justReached: Goal?
    /// What the parent chose to do next after a goal was reached: a new
    /// habit, or the same one again with another prize (the New habit sheet,
    /// shown by `ParentRootView`).
    @Published var nextHabit: NextHabit?
    private let key = "evlin.goals.v1"

    private init() {
        GoalProof.removeOldRecordings()
        // Lessons were removed (2026-11-05): forget their saved list.
        UserDefaults.standard.removeObject(forKey: "evlin.lessons.v1")
        // Let Mia choose was removed too (2026-11-05): forget saved picks.
        UserDefaults.standard.removeObject(forKey: "evlin.taskChoices")
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Goal].self, from: data) {
            goals = saved
        }
        // No photo checking on habits any more (2026-11-05): habits saved
        // with it ask for none from now on.
        if goals.contains(where: \.needsPhoto) {
            for i in goals.indices { goals[i].needsPhoto = false }
            save()
        }
        settleStreaks()
    }

    /// Streaks with a missed day go back to 0. On launch and on a new day
    /// (DayClock).
    func settleStreaks() {
        var changed = false
        for i in goals.indices where goals[i].streakBroken {
            goals[i].done = 0
            changed = true
        }
        if changed { save() }
    }

    /// The goals still running.
    func goals(for childId: String) -> [Goal] {
        goals.filter { $0.childId == childId && $0.finishedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Goals reached, newest first.
    func milestones(for childId: String) -> [Goal] {
        goals.filter { $0.childId == childId && $0.finishedAt != nil }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    /// Reached today: the kid sees the prize until the day ends.
    func prizesToday(for childId: String) -> [Goal] {
        milestones(for: childId).filter { $0.finishedAt.map(Calendar.current.isDateInToday) == true }
    }

    /// Reached: the goal becomes a milestone and leaves the running ones.
    func finish(_ goal: Goal) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i].done = goals[i].target
        goals[i].finishedAt = Date()
        save()
        justReached = goals[i]
    }

    @discardableResult
    func add(childId: String, title: String, target: Int, unit: String, prize: String,
             needsPhoto: Bool = false, picture: String? = nil) -> Goal {
        var goal = Goal(id: UUID().uuidString, childId: childId, title: title, target: target, unit: unit,
                        prize: prize, colorIndex: goals.filter { $0.childId == childId }.count,
                        needsPhoto: needsPhoto)
        goal.picture = picture == title ? nil : picture
        goals.append(goal)
        save()
        return goal
    }

    /// The parent changed its details. What's been counted stays.
    func update(_ goal: Goal, title: String, target: Int, prize: String, needsPhoto: Bool, picture: String? = nil) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i].title = title
        if let picture { goals[i].picture = picture == title ? nil : picture }
        goals[i].target = target
        goals[i].prize = prize
        goals[i].needsPhoto = false   // habits take no photos
        goals[i].done = min(goals[i].done, target)
        save()
    }

    /// The child: "I did it", now.
    func checkIn(_ goal: Goal, photo: String? = nil) {
        guard let i = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[i].entries.append(GoalCheckIn(at: Date(), photo: photo))
        save()
    }

    /// The parent's answer to one check-in. One that looks good adds to the
    /// count, on top of whatever's there: goals counted by hand before have
    /// no check-ins behind their number.
    /// Shows "Tap to approve" on Home's waiting habits until the first answer
    /// (2026-11-08: once, like the lock button's hints).
    static let approveHintKey = "evlin.approveHint"

    func review(_ goal: Goal, entry: String, approved: Bool) {
        UserDefaults.standard.set(false, forKey: Self.approveHintKey)
        guard let i = goals.firstIndex(where: { $0.id == goal.id }),
              let j = goals[i].entries.firstIndex(where: { $0.id == entry }) else { return }
        let last = goals[i].lastDay
        goals[i].entries[j].status = approved ? .approved : .notApproved
        if approved {
            let cal = Calendar.current
            if !goals[i].isStreak || last.map(cal.isDateInYesterday) == true {
                goals[i].done = min(goals[i].target, goals[i].done + 1)
            } else if last.map(cal.isDateInToday) != true {
                // The run starts again from this one.
                goals[i].done = 1
            }
        }
        save()
        // The check-in that reaches it.
        if approved && goals[i].reached && goals[i].finishedAt == nil { finish(goals[i]) }
    }

    func remove(_ goal: Goal) {
        goals.removeAll { $0.id == goal.id }
        save()
    }

    /// Replaces everything (the Demo app's sample goals).
    func replaceAll(_ new: [Goal]) {
        // Habits take no photos (the Demo's samples were made with them).
        var new = new
        for i in new.indices { new[i].needsPhoto = false }
        goals = new
        save()
    }

    func forgetChild(_ childId: String) {
        goals.removeAll { $0.childId == childId }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(goals) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The kinds of goal, the round icons at the top of New goal.
enum GoalCategory: String, CaseIterable, Identifiable {
    // The user's list (2026-11-05): Routines and Kindness removed, Helping
    // folded into Household. Household first (2026-11-16, the user's call),
    // then Hygiene & wellness (the heart), then Fitness (Hygiene first from
    // 2026-11-10; Fitness first before that).
    case household = "Household", wellness = "Hygiene & wellness", active = "Fitness & activity"
    case learning = "Learning", creative = "Creativity & arts"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .learning: return "book.fill"
        case .active: return "figure.run"
        case .creative: return "paintpalette.fill"
        case .household: return "house.fill"
        case .wellness: return "heart.fill"
        }
    }

    /// Its drawn picture across the top of New habit (`HabitArt`).
    var art: String {
        switch self {
        case .active: return "kind.active"
        case .wellness: return "kind.wellness"
        case .learning: return "Read for 20 minutes"
        case .creative: return "kind.creative"
        case .household: return "kind.household"
        }
    }
}

/// Goal ideas, by kind and age. "streak" ones are days in a row.
struct GoalIdea: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var target: Int
    var unit: String
    var prize: String
    var why: String
    var symbol: String
    var colorIndex: Int
    var ages: ClosedRange<Int>
    var category: GoalCategory
    /// The parent can change its name and keep its picture (a family's own
    /// language, what cleaning means at home).
    var renamable = false

    static let all: [GoalIdea] = [
        // Learning
        .init(title: "Read for 20 minutes", target: 14, unit: "days", prize: "A new book", why: "Two weeks of reading builds the habit.", symbol: "book.fill", colorIndex: 4, ages: 3...17, category: .learning),
        .init(title: "Play chess", target: 10, unit: "times", prize: "Board game night", why: "A game or a puzzle, ten times.", symbol: "checkerboard.rectangle", colorIndex: 2, ages: 3...17, category: .learning),
        // Worded for every family: the language spoken at home, whichever it is.
        .init(title: "Practice Spanish", target: 14, unit: "days", prize: "Taco night", why: "A few minutes of Spanish a day.", symbol: "character.bubble.fill", colorIndex: 1, ages: 3...17, category: .learning),
        .init(title: "Practice Mandarin", target: 14, unit: "days", prize: "Dumpling night", why: "A few minutes of Mandarin a day.", symbol: "character.bubble.fill", colorIndex: 0, ages: 3...17, category: .learning),
        // Fitness & activity
        .init(title: "Play outside", target: 14, unit: "days", prize: "Trip to the zoo", why: "An hour outside after school, most days.", symbol: "tree.fill", colorIndex: 1, ages: 3...17, category: .active),
        .init(title: "Skip rope", target: 10, unit: "times", prize: "A new skipping rope", why: "A few minutes, ten times.", symbol: "figure.jumprope", colorIndex: 5, ages: 3...17, category: .active),
        .init(title: "Play football", target: 12, unit: "times", prize: "A new football", why: "Kicks, passes, a goal or two.", symbol: "soccerball", colorIndex: 1, ages: 3...17, category: .active),
        .init(title: "Karate", target: 12, unit: "times", prize: "A new belt day out", why: "Class or practice at home.", symbol: "figure.martial.arts", colorIndex: 0, ages: 3...17, category: .active),
        .init(title: "Jiu-jitsu", target: 12, unit: "times", prize: "A day out together", why: "Class or drilling at home.", symbol: "figure.wrestling", colorIndex: 3, ages: 3...17, category: .active),
        .init(title: "Ride a bike", target: 10, unit: "times", prize: "Bike bell and streamers", why: "A ride, a little further each time.", symbol: "bicycle", colorIndex: 1, ages: 3...17, category: .active),
        .init(title: "Swimming", target: 10, unit: "times", prize: "Pool day with a friend", why: "Ten trips to the pool.", symbol: "figure.pool.swim", colorIndex: 4, ages: 3...17, category: .active),
        .init(title: "Play basketball", target: 12, unit: "times", prize: "A new basketball", why: "Shooting, dribbling, a game.", symbol: "basketball.fill", colorIndex: 0, ages: 3...17, category: .active),
        .init(title: "Yoga", target: 14, unit: "days", prize: "A new yoga mat", why: "Ten calm minutes.", symbol: "figure.yoga", colorIndex: 5, ages: 3...17, category: .active),
        // Creativity & arts
        .init(title: "Drawing", target: 15, unit: "times", prize: "A new sketchbook", why: "Fifteen pictures, anything at all.", symbol: "pencil.and.scribble", colorIndex: 5, ages: 3...17, category: .creative),
        .init(title: "Practice guitar", target: 20, unit: "times", prize: "Concert tickets", why: "Twenty practices, at their own pace.", symbol: "guitars.fill", colorIndex: 2, ages: 3...17, category: .creative),
        .init(title: "Practice piano", target: 20, unit: "times", prize: "Concert tickets", why: "Twenty practices, at their own pace.", symbol: "pianokeys", colorIndex: 2, ages: 3...17, category: .creative),
        .init(title: "Writing", target: 10, unit: "times", prize: "Print it as a book", why: "A story, a diary page, a poem.", symbol: "pencil.line", colorIndex: 4, ages: 3...17, category: .creative),
        // Household (Helping folded in)
        .init(title: "Ready for school", target: 10, unit: "days", prize: "A new backpack keyring", why: "Dressed, bag packed and at the door.", symbol: "backpack.fill", colorIndex: 0, ages: 3...17, category: .household),
        .init(title: "Feed the pet", target: 21, unit: "streak", prize: "A toy the pet will love", why: "Three weeks of looking after someone.", symbol: "pawprint.fill", colorIndex: 0, ages: 3...17, category: .household),
        .init(title: "Walk the dog", target: 14, unit: "days", prize: "A new lead for the dog", why: "Out with the dog, every day.", symbol: "dog.fill", colorIndex: 1, ages: 3...17, category: .household),
        .init(title: "Clean the house", target: 10, unit: "times", prize: "Pocket money bonus", why: "A room, a shelf, a floor.", symbol: "bubbles.and.sparkles.fill", colorIndex: 5, ages: 3...17, category: .household, renamable: true),
        .init(title: "Help with dinner", target: 10, unit: "times", prize: "Their own apron", why: "Cooking, setting or clearing.", symbol: "frying.pan.fill", colorIndex: 5, ages: 3...17, category: .household),
        .init(title: "Set the table", target: 10, unit: "times", prize: "Choose the dinner music", why: "A small job that helps everyone.", symbol: "fork.knife", colorIndex: 0, ages: 3...17, category: .household),
        .init(title: "Water the plants", target: 12, unit: "times", prize: "Pick a new plant", why: "They grow as the ring fills.", symbol: "drop.fill", colorIndex: 1, ages: 3...17, category: .household),
        .init(title: "Help with the laundry", target: 8, unit: "times", prize: "Pocket money bonus", why: "Sort, fold, put away.", symbol: "tshirt.fill", colorIndex: 3, ages: 3...17, category: .household),
        // Hygiene & wellness, every day (Brush your teeth removed,
        // 2026-11-16, the user's call; its picture stays for saved habits)
        .init(title: "Floss daily", target: 14, unit: "days", prize: "A new toothbrush", why: "Once a day, before bed.", symbol: "mouth", colorIndex: 4, ages: 3...17, category: .wellness),
        .init(title: "Take a shower or bath", target: 14, unit: "days", prize: "Bath bombs", why: "Every day, on their own.", symbol: "shower.fill", colorIndex: 4, ages: 3...17, category: .wellness),
        .init(title: "Take daily vitamins", target: 30, unit: "days", prize: "Smoothie date", why: "One a day, a month long.", symbol: "pills.fill", colorIndex: 1, ages: 3...17, category: .wellness),
    ]

    /// Two rewards that belong to each habit, its own prize first; then
    /// the same few treats for every habit (`treats`). 2026-11-08, the
    /// user's call.
    static let rewards: [String: [String]] = [
        // Fitness & activity
        "Play outside": ["Trip to the zoo", "Picnic in the park"],
        "Skip rope": ["A new skipping rope", "Trip to the trampoline park"],
        "Play football": ["A new football", "Watch a match together"],
        "Karate": ["A new belt day out", "Their own sparring gear"],
        "Jiu-jitsu": ["A day out together", "A new rash guard"],
        "Ride a bike": ["Bike bell and streamers", "New bike lights"],
        "Swimming": ["Pool day with a friend", "New goggles"],
        "Play basketball": ["A new basketball", "Watch a game together"],
        "Yoga": ["A new yoga mat", "Family yoga morning"],
        // Hygiene & wellness
        "Brush your teeth": ["Sticker book", "A toothbrush they pick"],
        "Floss daily": ["A new toothbrush", "Fun toothpaste"],
        "Take a shower or bath": ["Bath bombs", "Bath toys"],
        "Take daily vitamins": ["Smoothie date", "A new water bottle"],
        // Learning
        "Read for 20 minutes": ["A new book", "Trip to the bookshop"],
        "Play chess": ["Board game night", "A new chess set"],
        "Practice Spanish": ["Taco night", "A Spanish picture book"],
        "Practice Mandarin": ["Dumpling night", "A Mandarin picture book"],
        // Creativity & arts
        "Drawing": ["A new sketchbook", "Fancy pencils or pens"],
        "Practice guitar": ["Concert tickets", "New strings or picks"],
        "Practice piano": ["Concert tickets", "A songbook they pick"],
        "Writing": ["Print it as a book", "A new notebook"],
        // Household: helping at home
        "Ready for school": ["A new backpack keyring", "Lie-in on Saturday"],
        "Feed the pet": ["A toy the pet will love", "Trip to the pet shop"],
        "Walk the dog": ["A new lead for the dog", "Treats for the dog"],
        "Clean the house": ["Pocket money bonus", "Decorate their room"],
        "Help with dinner": ["Their own apron", "Grocery shopping together to pick dinner"],
        "Set the table": ["Choose the dinner music", "Pocket money bonus"],
        "Water the plants": ["Pick a new plant", "Their own watering can"],
        "Help with the laundry": ["Pocket money bonus", "A new pair of pyjamas"],
    ]

    /// After a habit's own two, a few treats drawn at random from these
    /// for every habit, different each time New habit opens (2026-11-08,
    /// the user's call: snacks, dinner, the toy store, the amusement park…).
    static let treats = [
        "Grocery shopping together to pick a snack", "Pick what's for dinner", "Pick the dessert",
        "Trip to the toy store", "Trip to the amusement park", "Trip to the movie theater",
        "Pizza night", "Ice cream outing", "Stay up 30 minutes later",
    ]

    /// Six treats at random for a habit the parent typed (2026-11-17).
    static func treats(seed: UInt64) -> [String] {
        var rng = SeededRandom(seed: seed)
        return Array(treats.shuffled(using: &rng).prefix(6))
    }

    /// Physical activities also get outings that fit the sport, two of them
    /// at random, before the general treats (2026-11-08).
    static let activityTreats: [String: [String]] = [
        "Play outside": ["Day at the beach", "Fly a kite together", "Picnic at the lake"],
        "Skip rope": ["A jump-rope game with friends", "Hopscotch chalk set", "Trip to the trampoline park"],
        "Play football": ["Kick-about at the park together", "A football shirt they pick", "Watch a match together"],
        "Karate": ["Watch a martial arts film together", "A day at the climbing wall", "A new belt bag"],
        "Jiu-jitsu": ["Open mat with a friend", "A day at the climbing wall", "Watch a tournament together"],
        "Ride a bike": ["Bike ride to the ice-cream shop", "A family bike trail day", "Pump track day"],
        "Swimming": ["Day at the water park", "Day at the beach", "Pool party with friends"],
        "Play basketball": ["Shoot hoops at the park together", "A jersey they pick", "Watch a game together"],
        "Yoga": ["Yoga in the park", "A day at the climbing wall", "Family stretch and smoothie morning"],
    ]

    /// The rewards to suggest for a habit, by its idea's name: its own two
    /// first (the default first of all), then picks at random. `seed`
    /// keeps one sheet's draw steady while it's open.
    static func rewards(for title: String, seed: UInt64 = 0) -> [String]? {
        guard let own = rewards[title] ?? all.first(where: { $0.title == title }).map({ [$0.prize] }) else { return nil }
        var rng = SeededRandom(seed: seed &+ UInt64(truncatingIfNeeded: title.hashValue))
        let sport = (activityTreats[title] ?? []).filter { !own.contains($0) }.shuffled(using: &rng).prefix(2)
        let picked = own + sport
        let rest = treats.filter { !picked.contains($0) }.shuffled(using: &rng).prefix(6 - picked.count)
        return picked + rest
    }

    /// What the child did, in the past, for the completed moment: "read for
    /// 20 minutes" in "Mia read for 20 minutes for 6 days." (2026-11-08: just
    /// the days felt lazy). Nil for a habit the parent typed.
    static let didIt: [String: String] = [
        "Play outside": "played outside", "Skip rope": "skipped rope", "Play football": "played football",
        "Karate": "practiced karate", "Jiu-jitsu": "practiced jiu-jitsu", "Ride a bike": "rode a bike",
        "Swimming": "went swimming", "Play basketball": "played basketball", "Yoga": "did yoga",
        "Brush your teeth": "brushed their teeth", "Floss daily": "flossed", "Take a shower or bath": "took a shower or bath",
        "Take daily vitamins": "took their vitamins", "Read for 20 minutes": "read for 20 minutes", "Play chess": "played chess",
        "Practice Spanish": "practiced Spanish", "Practice Mandarin": "practiced Mandarin", "Drawing": "drew",
        "Practice guitar": "practiced guitar", "Practice piano": "practiced piano", "Writing": "wrote",
        "Ready for school": "got ready for school", "Feed the pet": "fed the pet", "Walk the dog": "walked the dog",
        "Clean the house": "helped clean the house", "Help with dinner": "helped with dinner", "Set the table": "set the table",
        "Water the plants": "watered the plants", "Help with the laundry": "helped with the laundry",
    ]

    /// The ideas that suit `age`.
    static func picks(age: Int) -> [GoalIdea] {
        let fit = all.filter { $0.ages.contains(age) }
        return fit.count >= 3 ? fit : all
    }

    /// One kind's ideas that suit `age` (all of that kind if too few do).
    static func picks(age: Int, in category: GoalCategory) -> [GoalIdea] {
        let kind = all.filter { $0.category == category }
        let fit = kind.filter { $0.ages.contains(age) }
        return fit.count >= 3 ? fit : kind
    }
}

/// Whether a goal the parent typed suits a child of this age, said plainly,
/// with one Evlin would pick instead when it doesn't.
struct GoalAgeCheck: Equatable {
    enum Verdict { case empty, ok, notYet }
    var verdict: Verdict
    var message: String
    /// A goal to try instead.
    var instead: String? = nil

    private static let rules: [(pattern: String, why: String, instead: String)] = [
        (#"\b(lose|losing) (weight|kilos?|pounds?)\b|\bdiet|calorie|skinny|\bfasting\b"#,
         "Habits about weight aren't a fit for kids.", "Play outside"),
        (#"\bfollowers?\b|\bsubscribers?\b|\blikes\b|go viral|influencer"#,
         "Online fans aren't a habit at {age}.", "Learn 20 new words"),
        (#"\b(tiktok|instagram|snapchat|social media)\b"#,
         "Most social apps are for 13 and up.", "Read for 20 minutes"),
        (#"\b(drive|driving)\b|\bmake ?up\b|\bdating\b|\bboyfriend\b|\bgirlfriend\b"#,
         "That one's for when they're older.", "Cook a meal together"),
        (#"\b(stay up|all night|no sleep)\b"#,
         "Sleep matters a lot at {age}.", "Read for 20 minutes"),
        (#"\b(crypto|bitcoin|stocks?|invest\w*|gambl\w*|betting)\b"#,
         "Money like that is too much at {age}.", "Set the table"),
        (#"\b(fight|beat up|punch|weapon|gun|knife)\b"#,
         "That isn't something Evlin can help with.", "Play outside"),
        (#"\b(roblox|fortnite|minecraft|youtube|games?|gaming|screen ?time|ipad|phone)\b"#,
         "Screen time works better as the prize than the habit.", "Read for 20 minutes"),
    ]

    static func check(_ text: String, age: Int) -> GoalAgeCheck {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.count < 3 {
            return .init(verdict: .empty, message: "Anything they're working toward. Evlin checks it suits \(age).")
        }
        for rule in rules where t.range(of: rule.pattern, options: .regularExpression) != nil {
            return .init(verdict: .notYet, message: rule.why.replacingOccurrences(of: "{age}", with: "\(age)"),
                         instead: rule.instead)
        }
        // One word is a habit too ("Swimming", "Meditate"): two words were
        // asked for until 2026-11-15, and a one-word habit could never be
        // added, with nothing said why.
        return .init(verdict: .ok, message: "Right for \(age). How many and the prize are next.")
    }

    /// A typed goal tidied up, with any number in it as the count ("Swim
    /// 10 lengths" counts to 10).
    static func draft(from text: String) -> (title: String, target: Int, unit: String) {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        var target = 14
        if let r = title.range(of: #"\b\d{1,3}\b"#, options: .regularExpression), let n = Int(title[r]) {
            target = max(3, min(100, n))
        }
        let unit = title.range(of: #"\b(days?|daily|every day)\b"#, options: [.regularExpression, .caseInsensitive]) != nil ? "days" : "times"
        return (title, target, unit)
    }
}

/// A small seeded generator (SplitMix64), so a random draw can be repeated:
/// New habit's prize suggestions stay put while the sheet redraws.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
