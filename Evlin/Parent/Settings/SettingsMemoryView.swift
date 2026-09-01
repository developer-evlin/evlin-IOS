import SwiftUI

// Ported from Views/Settings/MemoryView.swift. The source lists rows from
// MemoryService (a network round-trip keyed by familyId); here the list is a
// local mock seeded once, grouped by category, with edit/delete acting on
// that local array only.
private struct MockMemory: Identifiable {
    let id = UUID()
    var text: String
    var category: String
    var confidence: String
    var userLocked: Bool
}

struct SettingsMemoryView: View {
    @State private var memories: [MockMemory] = [
        MockMemory(text: "Liam prefers a 30-minute Roblox session after homework.", category: "Preferences", confidence: "High confidence", userLocked: true),
        MockMemory(text: "Maya's bedtime wind-down starts at 8 PM on school nights.", category: "Rules", confidence: "High confidence", userLocked: false),
        MockMemory(text: "Noah responds better to task reminders phrased as questions.", category: "Preferences", confidence: "Medium confidence", userLocked: false),
        MockMemory(text: "Grandma Rose is allowed to approve bypass requests on weekends.", category: "People", confidence: "Medium confidence", userLocked: true),
    ]
    @State private var editing: MockMemory?

    private var grouped: [(String, [MockMemory])] {
        Dictionary(grouping: memories, by: \.category)
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(grouped, id: \.0) { category, items in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHead(category)
                        Card(padded: false) {
                            VStack(spacing: 0) {
                                ForEach(items) { memory in
                                    memoryRow(memory)
                                    if memory.id != items.last?.id { Divider().padding(.leading, 16) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .background(EColor.surface)
        .dismissKeyboardOnTap()
        .navigationTitle("What Evlin remembers")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { memory in
            SettingsEditMemorySheet(memory: memory) { updated in
                editing = nil
                if let updated, let index = memories.firstIndex(where: { $0.id == updated.id }) {
                    memories[index] = updated
                }
            }
        }
    }

    private func memoryRow(_ memory: MockMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.text).font(Typography.font(14, weight: .regular)).foregroundStyle(EColor.onSurface)
            HStack(spacing: 8) {
                if memory.userLocked {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                        Text("Locked").font(Typography.font(10, weight: .semibold))
                    }
                    .foregroundStyle(EColor.success)
                }
                Text(memory.confidence).font(Typography.font(10, weight: .regular)).foregroundStyle(EColor.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .swipeActions {
            Button("Edit") { editing = memory }.tint(EColor.primary)
            Button("Delete", role: .destructive) {
                memories.removeAll { $0.id == memory.id }
            }
        }
    }
}

private struct SettingsEditMemorySheet: View {
    let memory: MockMemory
    let onClose: (MockMemory?) -> Void
    @State private var text: String

    init(memory: MockMemory, onClose: @escaping (MockMemory?) -> Void) {
        self.memory = memory
        self.onClose = onClose
        _text = State(initialValue: memory.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Memory text", text: $text, axis: .vertical)
                    .font(Typography.font(15, weight: .regular))
                    .padding(14)
                    .background(EColor.surfaceContainerLowest)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
            }
            .padding(20)
            .background(EColor.surface)
            .dismissKeyboardOnTap()
            .navigationTitle("Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onClose(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = memory
                        updated.text = text
                        onClose(updated)
                    }
                    .disabled(text.count < 10)
                }
            }
        }
    }
}
