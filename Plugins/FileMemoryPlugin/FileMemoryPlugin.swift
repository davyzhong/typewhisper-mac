import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(FileMemoryPlugin)
final class FileMemoryPlugin: NSObject, TypeWhisperPlugin, MemoryStoragePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.memory.file"
    static let pluginName = "File Memory"

    var storageName: String { "File Memory" }
    var isReady: Bool { host != nil }
    var memoryCount: Int { memories.count }

    private var host: HostServices?
    private var memories: [MemoryEntry] = []
    private var memoriesFileURL: URL?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        memoriesFileURL = host.pluginDataDirectory.appendingPathComponent("memories.json")
        loadMemories()
    }

    func deactivate() {
        host = nil
        memories = []
        memoriesFileURL = nil
    }

    var settingsView: AnyView? {
        AnyView(FileMemorySettingsView(plugin: self))
    }

    // MARK: - MemoryStoragePlugin

    func store(_ entries: [MemoryEntry]) async throws {
        memories.append(contentsOf: entries)
        saveMemories()
    }

    func search(_ query: MemoryQuery) async throws -> [MemorySearchResult] {
        let queryTokens = tokenize(query.text)
        guard !queryTokens.isEmpty else { return [] }

        var results: [MemorySearchResult] = []
        let now = Date()

        for memory in memories {
            guard memory.confidence >= query.minConfidence else { continue }
            if let types = query.types, !types.contains(memory.type) { continue }

            let memoryTokens = tokenize(memory.content)
            guard !memoryTokens.isEmpty else { continue }

            let matchingTokens = queryTokens.filter { queryToken in
                memoryTokens.contains { $0.contains(queryToken) || queryToken.contains($0) }
            }

            let overlapScore = Double(matchingTokens.count) / Double(queryTokens.count)
            guard overlapScore > 0 else { continue }

            let daysSinceAccess = now.timeIntervalSince(memory.lastAccessedAt) / 86400
            let recencyBoost = 1.0 / (1.0 + daysSinceAccess * 0.01)
            let relevance = overlapScore * memory.confidence * recencyBoost

            results.append(MemorySearchResult(entry: memory, relevanceScore: relevance))
        }

        return results
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(query.maxResults)
            .map { $0 }
    }

    func delete(_ ids: [UUID]) async throws {
        memories.removeAll { ids.contains($0.id) }
        saveMemories()
    }

    func update(_ entry: MemoryEntry) async throws {
        guard let index = memories.firstIndex(where: { $0.id == entry.id }) else { return }
        memories[index] = entry
        saveMemories()
    }

    func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry] {
        let sorted = memories.sorted { $0.createdAt > $1.createdAt }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }

    func deleteAll() async throws {
        memories.removeAll()
        saveMemories()
    }

    // MARK: - Persistence

    private func loadMemories() {
        guard let url = memoriesFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            memories = try decoder.decode([MemoryEntry].self, from: data)
        } catch {
            memories = []
        }
    }

    private func saveMemories() {
        guard let url = memoriesFileURL else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(memories)
            try data.write(to: url, options: .atomic)
        } catch {
            // Silent failure - memory persistence is best-effort
        }
    }

    // MARK: - Tokenization

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    // MARK: - Public Accessors for Settings View

    func getAllMemories() -> [MemoryEntry] {
        memories.sorted { $0.createdAt > $1.createdAt }
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        saveMemories()
    }

    func updateMemoryContent(_ id: UUID, newContent: String) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index] = MemoryEntry(
            id: memories[index].id,
            content: newContent,
            type: memories[index].type,
            source: memories[index].source,
            metadata: memories[index].metadata,
            createdAt: memories[index].createdAt,
            lastAccessedAt: Date(),
            accessCount: memories[index].accessCount,
            confidence: memories[index].confidence
        )
        saveMemories()
    }

    func clearAll() {
        memories.removeAll()
        saveMemories()
    }
}

// MARK: - Settings View

private struct FileMemorySettingsView: View {
    let plugin: FileMemoryPlugin
    @State private var memories: [MemoryEntry] = []
    @State private var searchText = ""

    var filteredMemories: [MemoryEntry] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(memories.count) memories stored", systemImage: "brain.filled.head.profile")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    plugin.clearAll()
                    memories = []
                } label: {
                    Label(String(localized: "Clear All"), systemImage: "trash")
                }
                .disabled(memories.isEmpty)
            }

            TextField(String(localized: "Search memories..."), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredMemories.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Memories"), systemImage: "brain")
                } description: {
                    Text(searchText.isEmpty
                         ? String(localized: "Memories will appear here after transcriptions are processed.")
                         : String(localized: "No memories match your search."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRowView(
                            memory: memory,
                            onDelete: {
                                plugin.deleteMemory(memory.id)
                                memories = plugin.getAllMemories()
                            },
                            onSave: { newContent in
                                plugin.updateMemoryContent(memory.id, newContent: newContent)
                                memories = plugin.getAllMemories()
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .onAppear {
            memories = plugin.getAllMemories()
        }
    }
}

private struct MemoryRowView: View {
    let memory: MemoryEntry
    let onDelete: () -> Void
    let onSave: (String) -> Void
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField("", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !editText.trimmingCharacters(in: .whitespaces).isEmpty {
                            onSave(editText.trimmingCharacters(in: .whitespaces))
                        }
                        isEditing = false
                    }
                HStack {
                    Button(String(localized: "Cancel")) { isEditing = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Button(String(localized: "Save")) {
                        if !editText.trimmingCharacters(in: .whitespaces).isEmpty {
                            onSave(editText.trimmingCharacters(in: .whitespaces))
                        }
                        isEditing = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            } else {
                Text(memory.content)
                    .font(.body)
            }

            HStack(spacing: 8) {
                Text(memory.type.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15))
                    .clipShape(Capsule())

                if let app = memory.source.appName {
                    Text(app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(memory.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    editText = memory.content
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
