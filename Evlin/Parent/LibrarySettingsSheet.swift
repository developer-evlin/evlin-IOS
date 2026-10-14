import SwiftUI

/// The Library's settings button: what this child's videos may be — which
/// categories, how long, and the channels and words kept out. Saved to the
/// server (child_video_profiles); the Library will only offer videos that fit.
struct VideoSettingsSheet: View {
    let childId: String
    let childName: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ApiVideoProfile?
    @State private var newKeyword = ""
    @State private var saving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if let binding = Binding($draft) {
                    content(binding)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("\(childName)'s videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(draft == nil || saving)
                }
            }
            .task {
                await VideoQueueStore.shared.refresh(childId: childId, includeProfile: true)
                // Shown with the defaults when the server can't be reached
                // (or doesn't have video settings yet), so the page is never
                // just a spinner; Save then says plainly that it failed.
                draft = VideoQueueStore.shared.profile(childId) ?? .defaults(childId: childId)
            }
        }
    }

    @ViewBuilder
    private func content(_ p: Binding<ApiVideoProfile>) -> some View {
        Section {
            ForEach(p.wrappedValue.allCategories, id: \.self) { key in
                Toggle(isOn: Binding(
                    get: { p.wrappedValue.allowedCategories.contains(key) },
                    set: { on in
                        if on { p.wrappedValue.allowedCategories.append(key) }
                        else { p.wrappedValue.allowedCategories.removeAll { $0 == key } }
                    })) {
                    Label(VideoFormat.categoryName(key), systemImage: VideoFormat.categoryIcon(key))
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("The Library only offers videos from these categories.")
        }

        Section("Time") {
            Stepper("\(p.wrappedValue.dailyMinutes) min of video a day",
                    value: p.dailyMinutes, in: 5...240, step: 5)
            Stepper("Videos up to \(p.wrappedValue.maxVideoMinutes) min long",
                    value: p.maxVideoMinutes, in: 1...60)
        }

        Section {
            ForEach(p.wrappedValue.blockedKeywords, id: \.self) { word in
                Text(word)
            }
            .onDelete { p.wrappedValue.blockedKeywords.remove(atOffsets: $0) }
            HStack {
                TextField("Add a word, like \u{201C}prank\u{201D}", text: $newKeyword)
                    .textInputAutocapitalization(.never)
                    .onSubmit { addKeyword(p) }
                Button("Add") { addKeyword(p) }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Keep out videos that mention")
        }

        if !p.wrappedValue.blockedChannels.isEmpty {
            Section {
                ForEach(p.wrappedValue.blockedChannels, id: \.id) { channel in
                    Text(channel.title.isEmpty ? channel.id : channel.title)
                }
                .onDelete { p.wrappedValue.blockedChannels.remove(atOffsets: $0) }
            } header: {
                Text("Blocked channels")
            } footer: {
                Text("Swipe to unblock.")
            }
        }

        Section {
            Text("Videos play only inside Evlin, with nothing suggested after them. To stop \(childName) watching anything else, block the YouTube app with Chat's \u{201C}Block an app\u{201D} card.")
                .font(Typography.font(13))
                .foregroundStyle(EColor.onSurfaceVariant)
        }

        if let errorText {
            Text(errorText).foregroundStyle(.red)
        }
    }

    private func addKeyword(_ p: Binding<ApiVideoProfile>) {
        let word = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        if !p.wrappedValue.blockedKeywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            p.wrappedValue.blockedKeywords.append(word)
        }
        newKeyword = ""
    }

    private func save() {
        guard let draft else { return }
        saving = true
        Task {
            do {
                try await VideoQueueStore.shared.save(draft)
                dismiss()
            } catch {
                errorText = "Not saved. \(error.apiUserMessage)"
            }
            saving = false
        }
    }
}

extension ApiVideoProfile {
    /// The server's defaults for a child with nothing saved.
    static func defaults(childId: String) -> ApiVideoProfile {
        let all = ["science", "art", "math", "nature", "kitchen", "music", "reading", "mindful"]
        return ApiVideoProfile(childId: childId, allowedCategories: all, blockedKeywords: [],
                               allowedChannels: [], blockedChannels: [],
                               dailyMinutes: 30, maxVideoMinutes: 10, allCategories: all)
    }
}
