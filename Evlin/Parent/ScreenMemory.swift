import SwiftUI

/// Everything the assistant carries between conversations about one child.
///
/// This screen is the reason memory is plain readable rows instead of
/// embeddings: a parent should be able to see exactly what this thing
/// believes about their kid, and remove any of it. Facts are archived rather
/// than deleted server-side, so removing one is a decision that sticks —
/// it can't be re-learned from the same conversation later.
struct ScreenMemory: View {
    let childId: String
    let childName: String

    @State private var facts: [ApiChildMemory] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if facts.isEmpty {
                    emptyState
                } else {
                    ForEach(facts) { fact in
                        row(fact)
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(Typography.font(13, weight: .medium))
                        .foregroundStyle(Color(hex: "C2410C"))
                }
            }
            .padding(20)
        }
        .background(Brand.surfaceSoft.ignoresSafeArea())
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What Evlin remembers")
                .font(Typography.display(24, weight: .heavy))
            Text("Things it picked up about \(childName) in conversation, used to give better answers. Remove anything you'd rather it forgot.")
                .font(Typography.font(14))
                .foregroundStyle(Brand.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 26))
                .foregroundStyle(Brand.inkSoft)
            Text("Nothing yet")
                .font(Typography.font(16, weight: .bold))
            Text("As you chat about \(childName), anything worth remembering long-term will show up here.")
                .font(Typography.font(14))
                .foregroundStyle(Brand.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func row(_ fact: ApiChildMemory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: fact.category))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Brand.greenDeep)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Brand.greenTint))

            VStack(alignment: .leading, spacing: 3) {
                Text(fact.fact)
                    .font(Typography.font(15))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let label = label(for: fact.category) {
                    Text(label)
                        .font(Typography.font(12, weight: .semibold))
                        .foregroundStyle(Brand.inkSoft)
                }
            }
            Spacer(minLength: 0)

            Button {
                Task { await forget(fact) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Brand.inkSoft)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget: \(fact.fact)")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
        )
    }

    private func icon(for category: String?) -> String {
        switch category {
        case "routine": return "calendar"
        case "preference": return "heart"
        case "what_worked": return "lightbulb"
        default: return "text.quote"
        }
    }

    private func label(for category: String?) -> String? {
        switch category {
        case "routine": return "Routine"
        case "preference": return "Preference"
        case "what_worked": return "What worked"
        case "context": return "Context"
        default: return nil
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            facts = try await APIClient.shared.fetchMemory(childId: childId)
        } catch {
            errorText = "Couldn't load. \(error.apiUserMessage)"
        }
    }

    private func forget(_ fact: ApiChildMemory) async {
        do {
            try await APIClient.shared.forgetMemory(memoryId: fact.id)
            withAnimation(.easeOut(duration: 0.2)) {
                facts.removeAll { $0.id == fact.id }
            }
        } catch {
            errorText = "Couldn't remove that. \(error.apiUserMessage)"
        }
    }
}
