import SwiftUI

/// The kid's first look round (2026-11-16, the user's call): a shadow tour,
/// once per device, after the day's intro. The page dims and one thing is
/// lit at a time with a card: play time, a task, then on the Habits tab a
/// ring, three times (what habits are, press and hold, the parent approves).
/// Words for a 6 to 12 year old: short, plain, no jargon.
@MainActor
final class KidTour: ObservableObject {
    static let shared = KidTour()
    /// Set once the tour's been seen.
    static let doneKey = "evlin.kidTourDone"

    enum Spot { case playTime, task, ring }

    enum Step: Int, CaseIterable {
        case playTime, task, habit, hold, approve

        var spot: Spot {
            switch self {
            case .playTime: .playTime
            case .task: .task
            case .habit, .hold, .approve: .ring
            }
        }
        /// The tab it's on: Tasks (0) or Habits (1).
        var tab: Int { spot == .ring ? 1 : 0 }

        var title: String {
            switch self {
            case .playTime: "This is your play time"
            case .task: "Do your tasks"
            case .habit: "Build good habits"
            case .hold: "Press and hold"
            case .approve: "Your parent approves"
            }
        }

        var words: String {
            switch self {
            case .playTime: "Your iPad unlocks when your tasks are done and your parent approves them."
            case .task: "Do a task, then tap it and send it in. Your parent checks it."
            case .habit: "Habits are good things you do again and again, like reading. Each day you do one fills its ring a little."
            case .hold: "Did it today? Tap the ring, then press and hold the button until it fills up. That tells your parent."
            case .approve: "The ring turns orange while it waits. When your parent approves, it counts. Fill the ring to win your prize!"
            }
        }
    }

    @Published private(set) var step: Step?
    /// Where each lit thing is on screen, in global coordinates.
    @Published private(set) var frames: [Spot: CGRect] = [:]
    private var replayed = false

    func report(_ spot: Spot, _ frame: CGRect) {
        guard frames[spot] != frame else { return }
        frames[spot] = frame
    }

    /// Starts it, unless it's been seen.
    func startIfNew() {
        // Demo: `-EvlinKidTour` plays it again; other screens opened by a
        // flag (`-EvlinKidTab`) skip it, for clean screenshots.
        if DemoMode.kidTour && !replayed {
            replayed = true
            UserDefaults.standard.set(false, forKey: Self.doneKey)
        } else if DemoMode.isOn && DemoMode.kidTab != nil {
            return
        }
        guard step == nil, !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        withAnimation(.easeOut(duration: 0.35)) { step = Step(rawValue: DemoMode.kidTourStep) ?? .playTime }
    }

    func next() {
        guard let step else { return }
        if let after = Step(rawValue: step.rawValue + 1) {
            withAnimation(.easeOut(duration: 0.3)) { self.step = after }
        } else {
            UserDefaults.standard.set(true, forKey: Self.doneKey)
            withAnimation(.easeOut(duration: 0.3)) { self.step = nil }
        }
    }
}

extension View {
    /// Tells the kid's tour where this is.
    func kidTourSpot(_ spot: KidTour.Spot) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { KidTour.shared.report(spot, $0) }
    }
}

/// Reports where this is to the tour, when `on` (the first of a list).
struct KidTourFirst: ViewModifier {
    var on: Bool
    var spot: KidTour.Spot

    func body(content: Content) -> some View {
        if on { content.kidTourSpot(spot) } else { content }
    }
}

/// The tour over the whole of the kid's side (`TabletRootView`).
struct KidTourView: View {
    @ObservedObject private var tour = KidTour.shared
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        if let step = tour.step, let frame = tour.frames[step.spot] {
            let big = hSizeClass == .regular
            let last = step == .approve
            TourSpotlight(target: frame, pad: step.spot == .ring ? 14 : 10, cardWidth: 520) {
                TourCard(title: step.title, words: step.words, big: big) {
                    TourButton(title: last ? "Let's go!" : "Next", primary: true,
                               tint: KidTheme.paperButton, big: big) { tour.next() }
                }
            }
            .id(step)
            .transition(.opacity)
        }
    }
}
