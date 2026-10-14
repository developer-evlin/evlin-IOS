import SwiftUI

/// The kid's Library tab: their three bundles, one lesson from each a day.
/// Watching today's lesson to the end marks that bundle done for today and
/// moves it on. No locks or exercises yet — this is the layout, running on
/// LibrarySamples until the Library Agent exists.
struct ScreenTabletLibrary: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var kid: KidAdaptive { KidAdaptive(hSizeClass) }

    @State private var playing: PlayingLesson?
    private var store: LibraryStore { LibraryStore.shared }

    private struct PlayingLesson: Identifiable {
        let bundle: LibraryBundle
        let lesson: LibraryLesson
        var id: String { lesson.id }
    }

    private var childId: String { session.activeChildId ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(Typography.display(kid.of(30, 36), weight: .heavy))
                        .foregroundStyle(KidTheme.ink)
                    Text("Pick a bundle and start today's lesson.")
                        .font(Typography.font(kid.of(14, 16), weight: .semibold))
                        .foregroundStyle(KidTheme.inkSoft)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: kid.of(14, 20), alignment: .top),
                                             count: kid.isRegular ? 2 : 1),
                              spacing: kid.of(16, 22)) {
                        ForEach(store.shelf(childId)) { bundle in
                            card(bundle)
                        }
                    }
                    .padding(.top, 18)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 100)
                .kidContentColumn(kid.isRegular ? 900 : nil)
            }
            .background(KidTheme.background)
        }
        .fullScreenCover(item: $playing) { p in
            LibraryPlayerView(lesson: p.lesson, subtitle: p.bundle.name) {
                store.finishToday(childId, p.bundle)
            }
        }
    }

    private func card(_ bundle: LibraryBundle) -> some View {
        let today = store.todayLesson(childId, bundle)
        let finished = store.isFinished(childId, bundle)
        let doneToday = store.isDoneToday(childId, bundle)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.name)
                    .font(Typography.display(kid.of(20, 24), weight: .heavy))
                    .foregroundStyle(KidTheme.ink)
                Text("Lesson \(min(store.finishedCount(childId, bundle) + 1, bundle.lessons.count)) of \(bundle.lessons.count)")
                    .font(Typography.font(kid.of(13, 15), weight: .semibold))
                    .foregroundStyle(KidTheme.inkSoft)
            }
            LibraryBundleCover(bundle: bundle, lesson: today, cornerRadius: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(finished ? "You finished this bundle!" : "Today: \(today.title)")
                    .font(Typography.font(kid.of(16, 18), weight: .bold))
                    .foregroundStyle(KidTheme.ink)
                Text("\(today.channel) on YouTube")
                    .font(Typography.font(kid.of(13, 14), weight: .semibold))
                    .foregroundStyle(KidTheme.inkSoft)
            }

            if finished {
                cta("Bundle finished!", icon: "star.fill", enabled: false)
            } else if doneToday {
                cta("Done for today", icon: "checkmark", enabled: false)
            } else {
                Button { playing = PlayingLesson(bundle: bundle, lesson: today) } label: {
                    cta("Start today's lesson", icon: "play.fill", enabled: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(kid.of(14, 18))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(KidTheme.cream))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(KidTheme.line))
    }

    private func cta(_ title: String, icon: String, enabled: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(Typography.font(kid.of(16, 18), weight: .heavy))
            .foregroundStyle(enabled ? .white : KidTheme.greenDeep)
            .frame(maxWidth: .infinity)
            .frame(height: kid.of(52, 60))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(enabled ? KidTheme.greenDeep : KidTheme.greenTint))
    }
}
