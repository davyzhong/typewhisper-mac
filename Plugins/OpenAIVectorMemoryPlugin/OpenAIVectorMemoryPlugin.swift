import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(OpenAIVectorMemoryPlugin)
final class OpenAIVectorMemoryPlugin: NSObject, TypeWhisperPlugin, MemoryStoragePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.memory.openai-vector"
    static let pluginName = "OpenAI Vector Memory"

    var storageName: String { "OpenAI Vector Store" }
    var isReady: Bool { apiKey != nil && vectorStoreId != nil }
    var memoryCount: Int { localEntries.count }

    fileprivate var host: HostServices?
    fileprivate var apiKey: String?
    private var vectorStoreId: String?
    private var localEntries: [MemoryEntry] = []
    private var pendingEntries: [MemoryEntry] = []
    private var fileMapping: [UUID: String] = [:] // memoryId -> fileId
    private var localEntriesURL: URL?
    private var fileMappingURL: URL?
    private let batchSize = 10

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        apiKey = host.loadSecret(key: "api-key")
        vectorStoreId = host.userDefault(forKey: "vectorStoreId") as? String

        localEntriesURL = host.pluginDataDirectory.appendingPathComponent("entries.json")
        fileMappingURL = host.pluginDataDirectory.appendingPathComponent("file-mapping.json")

        loadLocalData()

        // Create vector store if we have a key but no store
        if apiKey != nil && vectorStoreId == nil {
            Task { await createVectorStoreIfNeeded() }
        }
    }

    func deactivate() {
        // Flush pending entries before deactivation
        if !pendingEntries.isEmpty {
            Task { try? await flushPendingEntries() }
        }
        host = nil
        apiKey = nil
    }

    var settingsView: AnyView? {
        AnyView(OpenAIVectorMemorySettingsView(plugin: self))
    }

    // MARK: - MemoryStoragePlugin

    func store(_ entries: [MemoryEntry]) async throws {
        localEntries.append(contentsOf: entries)
        pendingEntries.append(contentsOf: entries)
        saveLocalData()

        if pendingEntries.count >= batchSize {
            try await flushPendingEntries()
        }
    }

    func search(_ query: MemoryQuery) async throws -> [MemorySearchResult] {
        guard let key = apiKey, let storeId = vectorStoreId else { return [] }

        let url = URL(string: "https://api.openai.com/v1/vector_stores/\(storeId)/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")

        let body: [String: Any] = [
            "query": query.text,
            "max_num_results": query.maxResults
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return fallbackLocalSearch(query)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let results = json?["data"] as? [[String: Any]] else {
            return fallbackLocalSearch(query)
        }

        return results.compactMap { result -> MemorySearchResult? in
            guard let score = result["score"] as? Double,
                  let content = result["content"] as? [[String: Any]],
                  let firstContent = content.first,
                  let text = firstContent["text"] as? String else { return nil }

            // Try to find matching local entry by content
            if let entry = localEntries.first(where: { $0.content == text }) {
                return MemorySearchResult(entry: entry, relevanceScore: score)
            }

            // Create a transient entry from the search result
            let entry = MemoryEntry(content: text, type: .fact, confidence: score)
            return MemorySearchResult(entry: entry, relevanceScore: score)
        }
        .filter { $0.entry.confidence >= query.minConfidence }
    }

    func delete(_ ids: [UUID]) async throws {
        for id in ids {
            if let fileId = fileMapping[id] {
                try? await deleteFile(fileId)
                fileMapping.removeValue(forKey: id)
            }
        }
        localEntries.removeAll { ids.contains($0.id) }
        pendingEntries.removeAll { ids.contains($0.id) }
        saveLocalData()
    }

    func update(_ entry: MemoryEntry) async throws {
        if let index = localEntries.firstIndex(where: { $0.id == entry.id }) {
            localEntries[index] = entry
            saveLocalData()
        }
    }

    func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry] {
        let sorted = localEntries.sorted { $0.createdAt > $1.createdAt }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }

    func deleteAll() async throws {
        // Delete the vector store and create a new one
        if let storeId = vectorStoreId {
            try? await deleteVectorStore(storeId)
        }
        localEntries.removeAll()
        pendingEntries.removeAll()
        fileMapping.removeAll()
        vectorStoreId = nil
        saveLocalData()
        host?.setUserDefault(nil, forKey: "vectorStoreId")

        // Create a fresh store
        await createVectorStoreIfNeeded()
    }

    // MARK: - Vector Store Management

    private func createVectorStoreIfNeeded() async {
        guard let key = apiKey, vectorStoreId == nil else { return }

        let url = URL(string: "https://api.openai.com/v1/vector_stores")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")

        let body: [String: Any] = ["name": "TypeWhisper Memories"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15

        guard let (data, response) = try? await PluginHTTPClient.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storeId = json["id"] as? String else { return }

        vectorStoreId = storeId
        host?.setUserDefault(storeId, forKey: "vectorStoreId")
    }

    private func flushPendingEntries() async throws {
        guard let key = apiKey, let storeId = vectorStoreId, !pendingEntries.isEmpty else { return }

        let entriesToFlush = pendingEntries
        pendingEntries.removeAll()

        // Format entries as a text file for the vector store
        let content = entriesToFlush.map { entry in
            "[\(entry.type.rawValue)] \(entry.content)"
        }.joined(separator: "\n\n")

        // Upload file
        let fileId = try await uploadFile(content: content, apiKey: key)

        // Attach file to vector store
        try await attachFileToStore(fileId: fileId, storeId: storeId, apiKey: key)

        // Map entries to file
        for entry in entriesToFlush {
            fileMapping[entry.id] = fileId
        }
        saveLocalData()
    }

    private func uploadFile(content: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/files")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"purpose\"\r\n\r\n".data(using: .utf8)!)
        body.append("assistants\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"memories-\(UUID().uuidString.prefix(8)).txt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append(content.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, _) = try await PluginHTTPClient.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["id"] as? String else {
            throw PluginError.uploadFailed
        }
        return fileId
    }

    private func attachFileToStore(fileId: String, storeId: String, apiKey: String) async throws {
        let url = URL(string: "https://api.openai.com/v1/vector_stores/\(storeId)/files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileId])
        request.timeoutInterval = 15

        _ = try await PluginHTTPClient.data(for: request)
    }

    private func deleteFile(_ fileId: String) async throws {
        guard let key = apiKey else { return }
        let url = URL(string: "https://api.openai.com/v1/files/\(fileId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        _ = try? await PluginHTTPClient.data(for: request)
    }

    private func deleteVectorStore(_ storeId: String) async throws {
        guard let key = apiKey else { return }
        let url = URL(string: "https://api.openai.com/v1/vector_stores/\(storeId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = 10
        _ = try? await PluginHTTPClient.data(for: request)
    }

    // MARK: - Fallback Local Search

    private func fallbackLocalSearch(_ query: MemoryQuery) -> [MemorySearchResult] {
        let queryLower = query.text.lowercased()
        return localEntries
            .filter { $0.confidence >= query.minConfidence }
            .compactMap { entry -> MemorySearchResult? in
                let content = entry.content.lowercased()
                guard content.contains(queryLower) || queryLower.split(separator: " ").contains(where: { content.contains($0) }) else {
                    return nil
                }
                return MemorySearchResult(entry: entry, relevanceScore: 0.5 * entry.confidence)
            }
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(query.maxResults)
            .map { $0 }
    }

    // MARK: - Local Persistence

    private func loadLocalData() {
        if let url = localEntriesURL, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                localEntries = (try? decoder.decode([MemoryEntry].self, from: data)) ?? []
            }
        }

        if let url = fileMappingURL, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url) {
                let stringMapping = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                fileMapping = Dictionary(uniqueKeysWithValues: stringMapping.compactMap { key, value in
                    guard let uuid = UUID(uuidString: key) else { return nil }
                    return (uuid, value)
                })
            }
        }
    }

    private func saveLocalData() {
        if let url = localEntriesURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(localEntries) {
                try? data.write(to: url, options: .atomic)
            }
        }

        if let url = fileMappingURL {
            let stringMapping = Dictionary(uniqueKeysWithValues: fileMapping.map { ($0.key.uuidString, $0.value) })
            if let data = try? JSONEncoder().encode(stringMapping) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Public Accessors

    fileprivate func saveApiKey(_ key: String) {
        apiKey = key.isEmpty ? nil : key
        if key.isEmpty {
            try? host?.storeSecret(key: "api-key", value: "")
        } else {
            try? host?.storeSecret(key: "api-key", value: key)
        }
        host?.notifyCapabilitiesChanged()

        if apiKey != nil && vectorStoreId == nil {
            Task { await createVectorStoreIfNeeded() }
        }
    }

    fileprivate func getApiKey() -> String {
        apiKey ?? ""
    }

    fileprivate func getStoreId() -> String? {
        vectorStoreId
    }

    fileprivate func getAllMemories() -> [MemoryEntry] {
        localEntries.sorted { $0.createdAt > $1.createdAt }
    }

    fileprivate func deleteMemory(_ id: UUID) {
        localEntries.removeAll { $0.id == id }
        saveLocalData()
        if let fileId = fileMapping[id] {
            Task { try? await deleteFile(fileId) }
            fileMapping.removeValue(forKey: id)
        }
    }

    fileprivate func updateMemoryContent(_ id: UUID, newContent: String) {
        guard let index = localEntries.firstIndex(where: { $0.id == id }) else { return }
        localEntries[index] = MemoryEntry(
            id: localEntries[index].id,
            content: newContent,
            type: localEntries[index].type,
            source: localEntries[index].source,
            metadata: localEntries[index].metadata,
            createdAt: localEntries[index].createdAt,
            lastAccessedAt: Date(),
            accessCount: localEntries[index].accessCount,
            confidence: localEntries[index].confidence
        )
        saveLocalData()
    }

    fileprivate func clearAllSync() {
        Task { try? await deleteAll() }
    }

    private enum PluginError: Error {
        case uploadFailed
    }
}

// MARK: - Settings View

private struct OpenAIVectorMemorySettingsView: View {
    let plugin: OpenAIVectorMemoryPlugin
    @State private var apiKey = ""
    @State private var memories: [MemoryEntry] = []
    @State private var isKeyVisible = false
    @State private var searchText = ""

    var filteredMemories: [MemoryEntry] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // API Key + Status row
            HStack(spacing: 8) {
                if isKeyVisible {
                    TextField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                Button(String(localized: "Save")) {
                    plugin.saveApiKey(apiKey)
                }
            }

            // Status bar
            HStack {
                Image(systemName: plugin.isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(plugin.isReady ? .green : .red)
                    .font(.caption)
                Text(plugin.isReady ? String(localized: "Connected") : String(localized: "Not configured"))
                    .font(.caption)
                if let storeId = plugin.getStoreId() {
                    Text("(\(storeId.prefix(12))...)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Label("\(memories.count)", systemImage: "brain.filled.head.profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    plugin.clearAllSync()
                    memories = []
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(memories.isEmpty)
            }

            // Search + List
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
                        OpenAIMemoryRowView(
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
        .frame(minHeight: 400)
        .onAppear {
            apiKey = plugin.getApiKey()
            memories = plugin.getAllMemories()
        }
    }
}

private struct OpenAIMemoryRowView: View {
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
        .padding(.vertical, 2)
    }
}
