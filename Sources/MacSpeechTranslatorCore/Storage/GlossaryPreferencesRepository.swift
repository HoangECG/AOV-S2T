import Foundation

/// Stores the small, user-maintained glossary as Codable data in local
/// preferences. Audio and transcript content never enter this store.
public actor GlossaryPreferencesRepository: GlossaryRepository {
    private let preferences: UserDefaults
    private let key: String

    public init(preferences: UserDefaults = .standard, key: String = "MacSpeechTranslator.glossaryEntries") {
        self.preferences = preferences
        self.key = key
    }

    public func entries() throws -> [GlossaryEntry] {
        guard let data = preferences.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([GlossaryEntry].self, from: data)
        } catch {
            throw MacSpeechTranslatorError.storageFailed("The local glossary could not be read.")
        }
    }

    public func save(_ entries: [GlossaryEntry]) throws {
        do {
            preferences.set(try JSONEncoder().encode(entries), forKey: key)
        } catch {
            throw MacSpeechTranslatorError.storageFailed("The local glossary could not be saved.")
        }
    }
}
