import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MemoryService")

@MainActor
final class MemoryService: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: UserDefaultsKeys.memoryEnabled) }
    }
    @Published var extractionProviderId: String {
        didSet { UserDefaults.standard.set(extractionProviderId, forKey: UserDefaultsKeys.memoryExtractionProvider) }
    }
    @Published var extractionModel: String {
        didSet { UserDefaults.standard.set(extractionModel, forKey: UserDefaultsKeys.memoryExtractionModel) }
    }
    @Published var minimumTextLength: Int {
        didSet { UserDefaults.standard.set(minimumTextLength, forKey: UserDefaultsKeys.memoryMinTextLength) }
    }
    @Published var extractionPrompt: String {
        didSet { UserDefaults.standard.set(extractionPrompt, forKey: UserDefaultsKeys.memoryExtractionPrompt) }
    }

    static let defaultExtractionPrompt = """
    You extract ONLY lasting personal facts about the speaker from transcribed speech. \
    Return [] in 95% of cases - most speech contains nothing worth remembering permanently.

    ONLY extract if the speaker explicitly reveals:
    - Their name, job title, or employer
    - A long-term project they work on
    - A strong repeated preference ("I always...", "I prefer...")
    - Names of close colleagues or family members

    NEVER extract:
    - What the speaker is dictating (emails, notes, messages, tasks, questions)
    - Temporary plans ("meeting tomorrow", "need to call X")
    - Opinions, thoughts, or statements about any topic
    - Anything that sounds like content being dictated rather than self-revelation

    When in doubt: return []

    JSON format: [{"content": "...", "type": "fact", "confidence": 0.9}]
    Return ONLY the JSON array, nothing else.
    """

    private let promptProcessingService: PromptProcessingService
    private var eventSubscriptionId: UUID?

    init(promptProcessingService: PromptProcessingService) {
        self.promptProcessingService = promptProcessingService
        self.isEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.memoryEnabled)
        self.extractionProviderId = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionProvider) ?? ""
        self.extractionModel = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionModel) ?? ""
        self.minimumTextLength = UserDefaults.standard.object(forKey: UserDefaultsKeys.memoryMinTextLength) as? Int ?? 50
        let savedPrompt = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionPrompt) ?? ""
        self.extractionPrompt = savedPrompt.isEmpty ? Self.defaultExtractionPrompt : savedPrompt
    }

    // MARK: - Lifecycle

    func startListening() {
        guard eventSubscriptionId == nil else { return }
        eventSubscriptionId = EventBus.shared.subscribe { [weak self] event in
            switch event {
            case .transcriptionCompleted(let payload):
                await MainActor.run {
                    self?.handleTranscription(payload)
                }
            default:
                break
            }
        }
        logger.info("Memory service started listening")
    }

    func stopListening() {
        if let id = eventSubscriptionId {
            EventBus.shared.unsubscribe(id: id)
            eventSubscriptionId = nil
            logger.info("Memory service stopped listening")
        }
    }

    // MARK: - Extraction

    private func handleTranscription(_ payload: TranscriptionCompletedPayload) {
        guard isEnabled else { return }
        guard payload.finalText.count >= minimumTextLength else { return }

        // Check if the active profile has memory enabled
        if let profileName = payload.profileName,
           let profile = ServiceContainer.shared.profileService.profiles.first(where: { $0.name == profileName }) {
            guard profile.memoryEnabled else {
                logger.debug("Memory disabled for profile '\(profileName)', skipping extraction")
                return
            }
        } else {
            // No profile matched - skip extraction (memory is per-profile only)
            return
        }

        let providerId = extractionProviderId
        guard !providerId.isEmpty else {
            logger.debug("No extraction provider configured, skipping memory extraction")
            return
        }

        Task.detached { [weak self] in
            do {
                try await self?.extractAndStore(payload: payload, providerId: providerId)
            } catch {
                logger.error("Memory extraction failed: \(error.localizedDescription)")
            }
        }
    }

    private func extractAndStore(payload: TranscriptionCompletedPayload, providerId: String) async throws {
        let extractedEntries = try await extractMemories(from: payload, providerId: providerId)
        guard !extractedEntries.isEmpty else { return }

        let plugins = await MainActor.run { PluginManager.shared.memoryStoragePlugins }
        guard !plugins.isEmpty else {
            logger.debug("No memory storage plugins active")
            return
        }

        // Deduplicate against existing memories
        let deduplicatedEntries = await deduplicate(entries: extractedEntries, using: plugins)
        guard !deduplicatedEntries.isEmpty else {
            logger.debug("All extracted memories were duplicates")
            return
        }

        // Store in all active plugins
        for plugin in plugins where plugin.isReady {
            do {
                try await plugin.store(deduplicatedEntries)
                logger.info("Stored \(deduplicatedEntries.count) memories in \(plugin.storageName)")
            } catch {
                logger.error("Failed to store memories in \(plugin.storageName): \(error.localizedDescription)")
            }
        }
    }

    private func extractMemories(from payload: TranscriptionCompletedPayload, providerId: String) async throws -> [MemoryEntry] {
        let systemPrompt = await MainActor.run { extractionPrompt }

        let model = await MainActor.run { extractionModel }
        let result = try await promptProcessingService.process(
            prompt: systemPrompt,
            text: payload.finalText,
            providerOverride: providerId,
            cloudModelOverride: model.isEmpty ? nil : model
        )

        return parseExtractedMemories(result, source: MemorySource(
            appName: payload.appName,
            bundleIdentifier: payload.bundleIdentifier,
            profileName: payload.profileName,
            timestamp: payload.timestamp
        ))
    }

    private func parseExtractedMemories(_ json: String, source: MemorySource) -> [MemoryEntry] {
        // Extract JSON array from response (handle potential markdown wrapping)
        let cleaned = json
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return [] }

        struct RawMemory: Codable {
            let content: String
            let type: String
            let confidence: Double?
        }

        guard let rawMemories = try? JSONDecoder().decode([RawMemory].self, from: data) else {
            logger.warning("Failed to parse memory extraction response")
            return []
        }

        return rawMemories.compactMap { raw in
            guard let type = MemoryType(rawValue: raw.type) else { return nil }
            let confidence = raw.confidence ?? 0.8
            // Only store high-confidence memories
            guard confidence >= 0.8 else { return nil }
            return MemoryEntry(
                content: raw.content,
                type: type,
                source: source,
                confidence: raw.confidence ?? 0.8
            )
        }
    }

    // MARK: - Deduplication

    private func deduplicate(entries: [MemoryEntry], using plugins: [MemoryStoragePlugin]) async -> [MemoryEntry] {
        var unique: [MemoryEntry] = []

        for entry in entries {
            let query = MemoryQuery(text: entry.content, maxResults: 1, minConfidence: 0.0)
            var isDuplicate = false

            for plugin in plugins where plugin.isReady {
                if let results = try? await plugin.search(query),
                   let best = results.first,
                   best.relevanceScore > 0.85 {
                    // Update existing memory instead of creating a duplicate
                    var updated = best.entry
                    updated.lastAccessedAt = Date()
                    updated.accessCount += 1
                    try? await plugin.update(updated)
                    isDuplicate = true
                    break
                }
            }

            if !isDuplicate {
                unique.append(entry)
            }
        }

        return unique
    }

    // MARK: - Retrieval

    func retrieveRelevantMemories(for text: String) async -> String {
        guard isEnabled else { return "" }

        let plugins = PluginManager.shared.memoryStoragePlugins
        guard !plugins.isEmpty else { return "" }

        let query = MemoryQuery(text: text, maxResults: 10, minConfidence: 0.3)
        var allResults: [MemorySearchResult] = []

        for plugin in plugins where plugin.isReady {
            do {
                let results = try await plugin.search(query)
                allResults.append(contentsOf: results)
            } catch {
                logger.error("Memory search failed for \(plugin.storageName): \(error.localizedDescription)")
            }
        }

        guard !allResults.isEmpty else { return "" }

        // Deduplicate across plugins by content similarity, sort by relevance
        let deduplicated = deduplicateResults(allResults)
        let sorted = deduplicated.sorted { $0.relevanceScore > $1.relevanceScore }
        let top = Array(sorted.prefix(10))

        // Update access timestamps
        for result in top {
            var updated = result.entry
            updated.lastAccessedAt = Date()
            updated.accessCount += 1
            for plugin in plugins where plugin.isReady {
                try? await plugin.update(updated)
            }
        }

        return formatMemoriesForPrompt(top)
    }

    private func deduplicateResults(_ results: [MemorySearchResult]) -> [MemorySearchResult] {
        var seen = Set<String>()
        var unique: [MemorySearchResult] = []

        for result in results.sorted(by: { $0.relevanceScore > $1.relevanceScore }) {
            let normalized = result.entry.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.contains(normalized) {
                seen.insert(normalized)
                unique.append(result)
            }
        }

        return unique
    }

    private func formatMemoriesForPrompt(_ results: [MemorySearchResult]) -> String {
        let lines = results.map { "- \($0.entry.content)" }
        return """
        <memory_context>
        The following is known about the user from previous interactions:
        \(lines.joined(separator: "\n"))
        </memory_context>
        """
    }

    // MARK: - Correction Tracking

    func storeCorrections(_ corrections: [(original: String, replacement: String)], appName: String? = nil, bundleIdentifier: String? = nil) {
        guard isEnabled else { return }

        let plugins = PluginManager.shared.memoryStoragePlugins
        guard !plugins.isEmpty else { return }

        let entries = corrections.map { correction in
            MemoryEntry(
                content: "\(correction.replacement) (not \(correction.original))",
                type: .correction,
                source: MemorySource(
                    appName: appName,
                    bundleIdentifier: bundleIdentifier
                ),
                confidence: 1.0
            )
        }

        guard !entries.isEmpty else { return }

        Task.detached { [entries] in
            for plugin in plugins where plugin.isReady {
                do {
                    try await plugin.store(entries)
                    logger.info("Stored \(entries.count) correction(s) in \(plugin.storageName)")
                } catch {
                    logger.error("Failed to store corrections in \(plugin.storageName): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Management

    func clearAllMemories() async {
        let plugins = PluginManager.shared.memoryStoragePlugins
        for plugin in plugins {
            do {
                try await plugin.deleteAll()
                logger.info("Cleared all memories in \(plugin.storageName)")
            } catch {
                logger.error("Failed to clear memories in \(plugin.storageName): \(error.localizedDescription)")
            }
        }
    }
}
