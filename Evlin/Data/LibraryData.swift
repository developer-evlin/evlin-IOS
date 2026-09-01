import SwiftUI

struct LessonSlide: Identifiable {
    let id = UUID()
    var kind: String = "body" // "cover" | "body" | "takeaway"
    var kicker: String
    var headline: String
    var body: String? = nil
    var sub: String? = nil
    var points: [String]? = nil
    var icon: String
    var gradient: LinearGradient
}

struct SlideLesson: Identifiable {
    let id: String
    var category: String
    var title: String
    var subtitle: String
    var cover: LinearGradient
    var accent: Color
    var icon: String
    var slides: [LessonSlide]
}

struct ComicPanel: Identifiable {
    let id = UUID()
    var imageName: String
    var caption: String
}

struct ComicSeries: Identifiable {
    let id: String
    var author: String
    var role: String
    var title: String
    var excerpt: String
    var accent: Color
    var panels: [ComicPanel]
}

struct TopicCategory: Identifiable {
    let id = UUID()
    var count: String
    var label: String
    var gradient: LinearGradient
    var icon: String
}

enum LibraryData {
    static let visualLessons: [SlideLesson] = [
        SlideLesson(
            id: "anxious-gen", category: "Digital Wellbeing", title: "The Anxious Generation",
            subtitle: "Why childhood changed — and how to bring it back",
            cover: EGradient.anxiousGen, accent: Color(hex: "C4B5FD"), icon: "smartphone",
            slides: [
                LessonSlide(kind: "cover", kicker: "Digital Wellbeing", headline: "The Anxious\nGeneration", sub: "A 4-card lesson on screens, play, and growing up", icon: "smartphone", gradient: EGradient.anxiousGen),
                LessonSlide(kicker: "The big shift", headline: "Play-based childhood became phone-based", body: "Between 2010 and 2015, how kids spent their free time changed fast. Unstructured outdoor play quietly gave way to the scroll.", icon: "arrow.left.arrow.right", gradient: EGradient.anxiousGen),
                LessonSlide(kicker: "Why it matters", headline: "Free play is how kids build resilience", body: "Risk, boredom and minor conflict in real play teach children to handle discomfort. Remove it, and anxiety has more room to grow.", icon: "person.3.fill", gradient: EGradient.anxiousGen),
                LessonSlide(kicker: "The good news", headline: "It's reversible — and small moves count", body: "You don't need to ban technology. You need to protect the things it crowds out: sleep, play, and face-to-face time.", icon: "sun.max.fill", gradient: EGradient.anxiousGen),
                LessonSlide(kind: "takeaway", kicker: "Try tonight", headline: "Three small moves", points: ["Make bedrooms phone-free after 9pm", "Protect one block of unstructured play", "Delay the first personal smartphone"], icon: "lightbulb.fill", gradient: EGradient.anxiousGen),
            ]
        ),
        SlideLesson(
            id: "praise", category: "Growth Mindset", title: "The Science of Praise",
            subtitle: "The words that build (or quietly limit) your child",
            cover: EGradient.praise, accent: Color(hex: "5EEAD4"), icon: "sparkles",
            slides: [
                LessonSlide(kind: "cover", kicker: "Growth Mindset", headline: "The Science\nof Praise", sub: "How a single sentence shapes how kids face hard things", icon: "sparkles", gradient: EGradient.praise),
                LessonSlide(kicker: "The trap", headline: "\"You're so smart\" can backfire", body: "Praising ability makes kids protect the label. They start avoiding challenges where they might look less smart.", icon: "exclamationmark.triangle.fill", gradient: EGradient.praise),
                LessonSlide(kicker: "The fix", headline: "Praise the effort, not the talent", body: "\"You kept going when that got tricky\" rewards the strategy. Kids learn that struggle is the path, not a verdict.", icon: "figure.strengthtraining.traditional", gradient: EGradient.praise),
                LessonSlide(kicker: "The magic word", headline: "Add one word: \"yet\"", body: "\"I can't do this\" becomes \"I can't do this yet.\" It turns a closed door into a stage in a process.", icon: "chart.line.uptrend.xyaxis", gradient: EGradient.praise),
                LessonSlide(kind: "takeaway", kicker: "Try this week", headline: "Swap the script", points: ["Name the strategy, not the trait", "Add \"yet\" to \"I can't\"", "Get curious about mistakes together"], icon: "lightbulb.fill", gradient: EGradient.praise),
            ]
        ),
        SlideLesson(
            id: "tantrum", category: "Emotional Intelligence", title: "Riding the Wave",
            subtitle: "A calm-brain guide to the big meltdown",
            cover: EGradient.tantrum, accent: Color(hex: "FCD34D"), icon: "water.waves",
            slides: [
                LessonSlide(kind: "cover", kicker: "Emotional Intelligence", headline: "Riding\nthe Wave", sub: "What to do in the middle of a full meltdown", icon: "water.waves", gradient: EGradient.tantrum),
                LessonSlide(kicker: "The science", headline: "A meltdown is a brain offline", body: "In a tantrum the thinking brain goes quiet and the emotional brain takes over. Reasoning now simply can't land.", icon: "brain.head.profile", gradient: EGradient.tantrum),
                LessonSlide(kicker: "Step one", headline: "Connect before you correct", body: "Get low, soften your voice, name the feeling: \"You really wanted that.\" Safety comes before any lesson.", icon: "heart.fill", gradient: EGradient.tantrum),
                LessonSlide(kicker: "Step two", headline: "Be the calm they borrow", body: "Children co-regulate. Your steady breathing and slow tone are the signal their nervous system is waiting for.", icon: "figure.mind.and.body", gradient: EGradient.tantrum),
                LessonSlide(kind: "takeaway", kicker: "In the moment", headline: "Your meltdown kit", points: ["Lower your body and your voice", "Name the feeling out loud", "Wait for calm before the lesson"], icon: "lightbulb.fill", gradient: EGradient.tantrum),
            ]
        ),
    ]

    static let comics: [ComicSeries] = [
        ComicSeries(
            id: "weathering-the-meltdown", author: "Dr. Julian Vance", role: "Pediatric Neuropsychologist",
            title: "Weathering the Meltdown", excerpt: "A calm-brain guide to the big meltdown — told as a comic.",
            accent: Color(hex: "B45309"),
            panels: [
                ComicPanel(imageName: "TantrumCalmPanel1", caption: "One tower toppled, and the whole world ended."),
                ComicPanel(imageName: "TantrumCalmPanel2", caption: "First, she reminded herself: this wasn't defiance. It was a brain overloaded."),
                ComicPanel(imageName: "TantrumCalmPanel3", caption: "Step one: connect before you correct. Name the feeling, don't fix it yet."),
                ComicPanel(imageName: "TantrumCalmPanel4", caption: "Step two: be the calm they borrow. Kids' nervous systems copy ours."),
                ComicPanel(imageName: "TantrumCalmPanel5", caption: "She waited for calm to arrive before any lesson began."),
                ComicPanel(imageName: "TantrumCalmPanel6", caption: "The tower went back up. So did little Evlin's trust that big feelings are survivable."),
            ]
        ),
    ]

    static let categories: [TopicCategory] = [
        TopicCategory(count: "12 series", label: "Emotional Intelligence", gradient: EGradient.emotionalIntelligence, icon: "psychology"),
        TopicCategory(count: "8 series", label: "Digital Boundaries", gradient: EGradient.digitalBoundaries, icon: "shield"),
        TopicCategory(count: "15 series", label: "Conflict Resolution", gradient: EGradient.conflictResolution, icon: "handshake"),
        TopicCategory(count: "20 series", label: "Growth Mindset", gradient: EGradient.growthMindset, icon: "trending_up"),
    ]
}
