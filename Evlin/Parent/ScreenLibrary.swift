import SwiftUI

/// The parent's Library tab: each child's three bundles, one video from each
/// a day. The settings button opens the child's video settings; Change swaps
/// a bundle for another. Runs on LibrarySamples until the Library Agent
/// exists — see LibrarySampleData.swift.
struct ScreenLibrary: View {
    @Environment(SessionManager.self) private var session
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var adaptive: ParentAdaptive { ParentAdaptive(hSizeClass) }

    @State private var showSettings = false
    @State private var replacing: LibraryBundle?

    private var store: LibraryStore { LibraryStore.shared }

    private var child: Child? {
        _ = SyncState.shared.version
        let kids = FamilyStore.children
        return kids.first { $0.id == session.activeChildId } ?? kids.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if FamilyStore.children.count > 1 { childChips.padding(.top, 12) }

                    if let child {
                        Text("\(child.name)'s watchlist")
                            .font(Typography.font(19, weight: .bold))
                            .foregroundStyle(EColor.onSurface)
                            .padding(.top, 22)
                        // Says outright that these are what the child sees,
                        // so a parent reading this tab knows it's not a
                        // catalog to browse but the child's own list.
                        Label("These are the videos \(child.name) can watch in their Library: one from each bundle, every day.",
                              systemImage: "play.rectangle.on.rectangle")
                            .font(Typography.font(13, weight: .medium))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .padding(.top, 4)

                        VStack(spacing: 16) {
                            ForEach(store.shelf(child.id)) { bundle in
                                bundleCard(bundle, childId: child.id)
                            }
                        }
                        .padding(.top, 14)
                    } else {
                        Text("Add a child in Settings to set up their Library.")
                            .font(Typography.font(15))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 24)
                .parentContentColumn(adaptive.contentMaxWidth)
            }
            .background(EColor.surface)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: LibraryBundle.self) { bundle in
                if let child { LibraryBundleDetail(bundle: bundle, childId: child.id, childName: child.name) }
            }
        }
        .sheet(isPresented: $showSettings) {
            Group {
            if let child { VideoSettingsSheet(childId: child.id, childName: child.name) }
        }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $replacing) { bundle in
            Group {
            if let child {
                LibraryBundlePicker(childId: child.id, childName: child.name, replacing: bundle)
            }
        }
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            Text("Library")
                .font(Typography.font(32, weight: .heavy))
                .foregroundStyle(EColor.onSurface)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(EColor.primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Library settings")
            .disabled(child == nil)
        }
    }

    private var childChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FamilyStore.children, id: \.id) { kid in
                    let selected = kid.id == child?.id
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { session.activeChildId = kid.id }
                    } label: {
                        HStack(spacing: 7) {
                            Text(String(kid.name.prefix(1)).uppercased())
                                .font(Typography.font(11, weight: .heavy))
                                .foregroundStyle(kid.color)
                                .frame(width: 24, height: 24)
                                .background(kid.color.opacity(0.16), in: Circle())
                            Text(kid.age > 0 ? "\(kid.name), \(kid.age)" : kid.name)
                                .font(Typography.font(14, weight: .semibold))
                                .foregroundStyle(EColor.onSurface)
                        }
                        .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
                        .background(Capsule().fill(selected ? EColor.surfaceContainerLowest : .clear))
                        .overlay(Capsule().strokeBorder(selected ? EColor.onSurface : EColor.outlineVariant,
                                                        lineWidth: selected ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func bundleCard(_ bundle: LibraryBundle, childId: String) -> some View {
        let today = store.todayLesson(childId, bundle)
        let finished = store.isFinished(childId, bundle)
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: bundle) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bundle.name)
                            .font(Typography.font(20, weight: .bold))
                            .foregroundStyle(EColor.onSurface)
                        Text("\(bundle.subject.name) · ages \(bundle.ages) · \(bundle.lessons.count) lessons")
                            .font(Typography.font(13, weight: .medium))
                            .foregroundStyle(EColor.onSurfaceVariant)
                    }
                    LibraryBundleCover(bundle: bundle, lesson: today)
                    HStack(spacing: 10) {
                        Text(String(today.channel.prefix(1)))
                            .font(Typography.font(13, weight: .heavy))
                            .foregroundStyle(EColor.onSurface)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(EColor.surfaceContainerHigh))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finished ? "Bundle finished" : "Today: \(today.title)")
                                .font(Typography.font(14, weight: .bold))
                                .foregroundStyle(EColor.onSurface)
                                .lineLimit(1)
                            Text("\(today.channel) on YouTube")
                                .font(Typography.font(12))
                                .foregroundStyle(EColor.onSurfaceVariant)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        progressDots(done: store.finishedCount(childId, bundle), total: bundle.lessons.count)
                    }
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Spacer()
                Button("Change") { replacing = bundle }
                    .font(Typography.font(13, weight: .semibold))
                    .foregroundStyle(EColor.primary)
                    .frame(minHeight: 32)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, -6)
        }
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(EColor.outlineVariant))
    }

    private func progressDots(done: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < done ? Brand.greenDeep : EColor.outlineVariant)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(total) lessons done")
    }
}

/// A bundle's lessons in order: done, today's, and what comes after. Tapping
/// one previews it in the same player the child uses.
struct LibraryBundleDetail: View {
    let bundle: LibraryBundle
    let childId: String
    let childName: String

    @State private var previewing: LibraryLesson?
    private var store: LibraryStore { LibraryStore.shared }

    var body: some View {
        let done = store.finishedCount(childId, bundle)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(bundle.subject.name.uppercased()) BUNDLE · AGES \(bundle.ages)", systemImage: bundle.subject.icon)
                        .font(Typography.font(11, weight: .bold)).tracking(0.5)
                        .foregroundStyle(bundle.subject.tint)
                    Text(bundle.name)
                        .font(Typography.font(26, weight: .heavy))
                        .foregroundStyle(EColor.onSurface)
                    Text("\(bundle.lessons.count) lessons, one a day. \(bundle.why).")
                        .font(Typography.font(14))
                        .foregroundStyle(EColor.onSurfaceVariant)
                }

                ForEach(Array(bundle.lessons.enumerated()), id: \.element.id) { i, lesson in
                    Button { previewing = lesson } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(i < done ? Brand.greenDeep : .clear)
                                    .overlay(Circle().strokeBorder(i < done ? .clear : EColor.outlineVariant, lineWidth: 1.5))
                                if i < done {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                } else {
                                    Text("\(i + 1)").font(Typography.font(12, weight: .bold)).foregroundStyle(EColor.onSurface)
                                }
                            }
                            .frame(width: 26, height: 26)

                            VideoThumbnail(url: lesson.thumbnailURL, durationSeconds: lesson.seconds, cornerRadius: 8)
                                .frame(width: 110)
                            VStack(alignment: .leading, spacing: 3) {
                                if i == done {
                                    Text("TODAY")
                                        .font(Typography.font(10, weight: .heavy)).tracking(0.6)
                                        .foregroundStyle(Brand.greenDeep)
                                }
                                Text(lesson.title)
                                    .font(Typography.font(15, weight: .semibold))
                                    .foregroundStyle(EColor.onSurface)
                                    .multilineTextAlignment(.leading)
                                Text("\(lesson.channel) · \(lesson.minutes) min")
                                    .font(Typography.font(12))
                                    .foregroundStyle(EColor.onSurfaceVariant)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Preview this video")
                }

                Label("Made for kids. Plays in YouTube's own player, with no autoplay after it.",
                      systemImage: "checkmark.shield")
                    .font(Typography.font(12))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .background(EColor.surface)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $previewing) { lesson in
            LibraryPlayerView(lesson: lesson, subtitle: "Preview · \(bundle.name)")
        }
    }
}

/// Change: other bundles, filtered by subject, any of which can take the
/// replaced one's place. The parent picks; nothing is chosen for them.
struct LibraryBundlePicker: View {
    let childId: String
    let childName: String
    let replacing: LibraryBundle

    @Environment(\.dismiss) private var dismiss
    @State private var subject: LibrarySubject?
    private var store: LibraryStore { LibraryStore.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pick one to take the place of \(replacing.name).")
                        .font(Typography.font(14))
                        .foregroundStyle(EColor.onSurfaceVariant)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All", selected: subject == nil) { subject = nil }
                            ForEach(LibrarySubject.allCases) { s in
                                chip(s.name, selected: subject == s) { subject = s }
                            }
                        }
                    }

                    let options = store.alternatives(childId, subject: subject)
                    if options.isEmpty {
                        Text("No other \(subject?.name.lowercased() ?? "") bundles yet.")
                            .font(Typography.font(14))
                            .foregroundStyle(EColor.onSurfaceVariant)
                            .padding(.top, 8)
                    }
                    ForEach(options) { bundle in
                        option(bundle)
                    }
                }
                .padding(20)
            }
            .background(EColor.surface)
            .navigationTitle("Change \(replacing.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typography.font(14, weight: .semibold))
                .foregroundStyle(selected ? .white : EColor.onSurface)
                .padding(.horizontal, 14).frame(height: 34)
                .background(Capsule().fill(selected ? EColor.primary : EColor.surfaceContainerLowest))
                .overlay(Capsule().strokeBorder(selected ? .clear : EColor.outlineVariant))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func option(_ bundle: LibraryBundle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.name)
                    .font(Typography.font(18, weight: .bold))
                    .foregroundStyle(EColor.onSurface)
                Text("\(bundle.subject.name) · ages \(bundle.ages) · \(bundle.why)")
                    .font(Typography.font(13))
                    .foregroundStyle(EColor.onSurfaceVariant)
            }
            LibraryBundleCover(bundle: bundle, lesson: bundle.lessons[0])
            Button {
                store.swap(childId, remove: replacing.id, add: bundle.id)
                dismiss()
            } label: {
                Text("Use instead")
                    .font(Typography.font(15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Brand.greenDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(EColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(EColor.outlineVariant))
    }
}
