import Foundation

struct ApiTask: Codable {
    let id: String
    let title: String
    let instructions: String?
    let recurrence: String
    let gatesApps: Bool
    let submissionKind: String
    // `bucket` is a DB time-of-day grouping the server derives from due_time
    // and never trusts from the client — see routers/tasks.py. `category` is
    // the free-form UI label ("Chore", "Study", …).
    let bucket: String
    let category: String?
    let dueDate: String?   // "YYYY-MM-DD"
    let dueTime: String?   // "HH:MM:SS"
    let createdAt: String?
    // Minutes awarded to time_grants once this task's occurrence is
    // approved (0 = no bonus) and who authored the task's content —
    // see evlin-backend's TaskBase.
    let bonusMinutes: Int
    let createdBy: String
}

struct ApiEvent: Codable {
    let id: String
    let childId: String?   // nil = family-wide
    let title: String
    let startAt: String
    let endAt: String
    let locationOrLink: String?
    let source: String
    let isParentOnly: Bool
    let category: String?
    let note: String?
    let recurrence: String
}

struct ApiOccurrence: Codable {
    let id: String
    let taskId: String
    let childId: String
    let dueDate: String
    let status: String
    let bypassRequested: Bool
    let bypassNote: String?
    let rejectionNote: String?
}

struct ApiChildRule: Codable {
    let dailyLimitMinutes: Int
    let downtimeEnabled: Bool
    let downtimeStart: String?
    let downtimeEnd: String?
    let dailyLimitEnabled: Bool?
    let customRules: [ApiCustomRule]?
    // Calendar-style override: weekday code ("mon".."sun") -> minutes.
    // nil/absent means "use dailyLimitMinutes every day."
    let weeklySchedule: [String: Int]?
}

struct ApiCustomRule: Codable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let on: Bool
}

struct ApiChildState: Codable {
    let manualLock: Bool
    let taskGateOverride: Bool
    /// Server-computed, not a stored column: an unresolved reflection is
    /// holding the gate closed. Independent of the task gate — a pending
    /// reflection locks regardless of task status, and clearing it doesn't
    /// satisfy outstanding tasks. Optional so an older backend still decodes.
    let hasOpenReflection: Bool?
}

struct ApiChild: Codable {
    let id: String
    let name: String
    let colorIndex: Int
    let isPaired: Bool
}

struct ApiParent: Codable {
    let id: String
    let email: String
    let name: String?
}

struct ApiSubmission: Codable {
    let id: String
    let occurrenceId: String
    let kind: String
    let status: String
    let downloadUrl: String?
}

// One append-only ledger row — signed (a deduction is negative), never a
// mutable balance. See evlin-backend's TimeGrant/routers/time_grants.py.
struct ApiTimeGrant: Codable {
    let id: String
    let childId: String
    let minutes: Int
    let source: String        // "manual" | "task_bonus" | "milestone" | "ai_agent"
    let reason: String?
    let createdBy: String     // "parent" | "ai_agent" | "system"
    let grantedByParentId: String?
    let sourceRefId: String?
    let creditedDate: String  // "YYYY-MM-DD"
    let createdAt: String
}

struct ApiTimeGrantsSummary: Codable {
    let date: String
    let dailyLimitMinutes: Int
    let grantedMinutes: Int
    let availableMinutes: Int
    let grants: [ApiTimeGrant]
}

struct ApiChatMessage: Codable {
    let id: String
    let childId: String
    let role: String        // "user" | "assistant"
    let text: String
    // "draft_task" | "open_block_picker" | "propose_reflection" |
    // "generate_course" | "draft_special_task" | nil
    let toolCall: String?
    // Always strings on the wire — the backend coerces numeric tool args
    // before storing precisely so this stays decodable (one raw JSON number
    // here would fail the whole message, and with it the transcript).
    let toolArgs: [String: String]?
    let createdAt: String
}

// MARK: - Courses
//
// Shared vetted content (ApiCourse/ApiCourseItem, no child) vs. one child's
// progress through it (ApiCourseAssignment/ApiCourseItemProgress). Vetting
// happens once; siblings get their own independent progress. See
// evlin-backend/models.py's Course.

/// Decoded leniently on purpose: these come from a jsonb column originally
/// written by the model, and one malformed question would otherwise fail the
/// whole course — taking the screen with it rather than just that question.
struct ApiQuizQuestion: Codable, Hashable {
    let question: String
    let options: [String]
    let correctIndex: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = (try? c.decode(String.self, forKey: .question)) ?? ""
        options = (try? c.decode([String].self, forKey: .options)) ?? []
        correctIndex = (try? c.decode(Int.self, forKey: .correctIndex)) ?? 0
    }

    /// A question the kid can't actually answer isn't worth showing.
    var isUsable: Bool { !question.isEmpty && options.count >= 2 }
}

struct ApiCourseItem: Codable {
    let id: String
    let orderIndex: Int
    let videoId: String          // YouTube video id — the only source
    let videoTitle: String?
    let channelTitle: String?
    let vettingNotes: String?    // why the agent picked it, shown to the parent
    let quiz: [ApiQuizQuestion]
}

struct ApiCourse: Codable {
    let id: String
    let title: String
    let topic: String?
    let category: String?
    let status: String           // "pending_review" | "published" | "archived"
    let createdBy: String        // "parent" | "ai_agent"
    let createdAt: String
    let publishedAt: String?
    let items: [ApiCourseItem]
}

struct ApiCourseItemProgress: Codable {
    let id: String
    let assignmentId: String
    let courseItemId: String
    let status: String           // "locked" | "available" | "completed"
    let quizAnswers: [Int]?
    let quizScore: Int?
    let completedAt: String?
}

struct ApiCourseAssignment: Codable {
    let id: String
    let courseId: String
    let childId: String
    let status: String           // "active" | "completed"
    let assignedBy: String
    let createdAt: String
    let completedAt: String?
    let course: ApiCourse?
    let progress: [ApiCourseItemProgress]

    /// Progress rows in the course's own order — the order they unlock in.
    var orderedProgress: [ApiCourseItemProgress] {
        guard let items = course?.items else { return progress }
        let position = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.orderIndex) })
        return progress.sorted { (position[$0.courseItemId] ?? 0) < (position[$1.courseItemId] ?? 0) }
    }

    func item(for progress: ApiCourseItemProgress) -> ApiCourseItem? {
        course?.items.first { $0.id == progress.courseItemId }
    }
}

/// One YouTube search result, for the parent picking a single video.
struct ApiVideoSearchResult: Codable, Identifiable {
    let videoId: String
    let title: String
    let channelTitle: String?
    let thumbnailUrl: String?
    let duration: String?
    let madeForKids: Bool?

    var id: String { videoId }
}

// MARK: - Reflections

struct ApiReflection: Codable {
    let id: String
    let childId: String
    let courseAssignmentId: String
    let writtenPrompt: String?
    let writtenResponse: String?
    // "pending" | "submitted" | "approved" | "needs_redo". Both "pending" and
    // "submitted" hold the gate closed.
    let status: String
    let reviewNote: String?
    let createdBy: String
    let createdAt: String
    let submittedAt: String?
    let reviewedAt: String?
    let assignment: ApiCourseAssignment?
}

// MARK: - Milestones

struct ApiMilestone: Codable {
    let id: String
    let childId: String
    let title: String
    let description: String?
    let kind: String             // "count" | "streak" | "course" | "custom"
    let targetCount: Int?
    let progressCount: Int
    let courseAssignmentId: String?
    let prizeText: String?
    let prizeMinutes: Int
    let status: String           // "active" | "achieved" | "expired"
    let createdBy: String
    let createdAt: String
    let achievedAt: String?
    /// Server-computed: whether what this asks for is actually done. Means
    /// two different things by kind, so the client just reads the answer.
    let achievable: Bool
    let assignment: ApiCourseAssignment?
}

/// An AI-proposed milestone the parent edits before it's created. Not a
/// milestone yet — nothing exists server-side until they confirm.
struct ApiMilestoneDraft: Codable {
    let title: String
    let description: String?
    let kind: String
    let targetCount: Int?
    let prizeText: String?
    let prizeMinutes: Int?
    let createdBy: String
}

// MARK: - App blocks

struct ApiAppBlock: Codable {
    let id: String
    let childId: String
    let appName: String
    let appBundleId: String?
    let blockType: String        // "duration" | "until_task"
    let durationMinutes: Int?
    let untilTaskId: String?
    let resolved: Bool
    let createdBy: String
    let createdAt: String
    let resolvedAt: String?
}
