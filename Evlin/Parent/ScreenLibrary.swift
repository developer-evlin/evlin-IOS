import SwiftUI

struct ScreenLibrary: View {
    @State private var activeLesson: SlideLesson?
    @State private var activeComic: ComicSeries?
    @State private var selectedCategory: TopicCategory?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead("Trending Lessons") {
                            Text("SWIPE TO LEARN")
                                .font(Typography.font(10, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(EColor.onSurfaceVariant)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(LibraryData.visualLessons) { lesson in
                                    LessonPosterCard(lesson: lesson) { activeLesson = lesson }
                                }
                                ForEach(LibraryData.comics) { comic in
                                    ComicPosterCard(comic: comic) { activeComic = comic }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead("Topic Categories")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(LibraryData.categories) { cat in
                                TopicCategoryTile(category: cat) { selectedCategory = cat }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .background(EColor.surface)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
        }
        .fullScreenCover(item: $activeLesson) { lesson in
            LessonReaderView(lesson: lesson)
        }
        .fullScreenCover(item: $activeComic) { comic in
            ComicReaderView(comic: comic)
        }
    }
}

private struct TopicCategoryTile: View {
    var category: TopicCategory
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading) {
                Image(systemName: EIcon.sf(category.icon))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer()
                Text(category.count.uppercased())
                    .font(Typography.font(9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.55))
                Text(category.label)
                    .font(Typography.font(16, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1.1, contentMode: .fit)
            .background(category.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: EShadow.premium, radius: EShadow.premiumRadius, y: EShadow.premiumY)
        }
        .buttonStyle(.plain)
    }
}

// Poster card for a swipe-through text lesson (VISUAL_LESSONS equivalent).
private struct LessonPosterCard: View {
    var lesson: SlideLesson
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: EIcon.sf(lesson.icon))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack").font(.system(size: 11))
                        Text("\(lesson.slides.count)").font(Typography.font(10, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.28))
                    .clipShape(Capsule())
                }
                Spacer()
                Text(lesson.category.uppercased())
                    .font(Typography.font(9, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(lesson.accent)
                Text(lesson.title)
                    .font(Typography.font(19, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.top, 4)
                Text(lesson.subtitle)
                    .font(Typography.font(11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.top, 6)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text("Start").font(Typography.font(11, weight: .heavy))
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.top, 10)
            }
            .padding(16)
            .frame(width: 178, height: 237, alignment: .topLeading)
            .background(lesson.cover)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: EShadow.premium, radius: EShadow.premiumRadius, y: EShadow.premiumY)
        }
        .buttonStyle(.plain)
    }
}

// Poster card for a real illustrated comic — cover = first panel artwork.
private struct ComicPosterCard: View {
    var comic: ComicSeries
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                if let first = comic.panels.first {
                    Image(first.imageName)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "book.pages")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.white.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "book.pages").font(.system(size: 11))
                            Text("\(comic.panels.count)").font(Typography.font(10, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.black.opacity(0.4))
                        .clipShape(Capsule())
                    }
                    Spacer()
                    Text("COMIC")
                        .font(Typography.font(9, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(comic.accent)
                    Text(comic.title)
                        .font(Typography.font(19, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.top, 4)
                    Text(comic.excerpt)
                        .font(Typography.font(11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 6)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text("Read").font(Typography.font(11, weight: .heavy))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.top, 10)
                }
                .padding(16)
            }
            .frame(width: 178, height: 237)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.black, lineWidth: 2.5)
            )
            .shadow(color: EShadow.premium, radius: EShadow.premiumRadius, y: EShadow.premiumY)
        }
        .buttonStyle(.plain)
    }
}
