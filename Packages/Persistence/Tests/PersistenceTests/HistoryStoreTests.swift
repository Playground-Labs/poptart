import CryptoKit
import Foundation
import Testing

@testable import Persistence

@Suite("Encrypted local persistence")
struct HistoryStoreTests {
  @Test("Dictation Records round-trip while sensitive values stay encrypted at rest")
  func encryptedRoundTrip() async throws {
    let fixture = try Fixture()
    let keyProvider = InMemoryKeyProvider()
    let store = try HistoryStore(
      directory: fixture.directory,
      keyProvider: keyProvider,
      now: { Date(timeIntervalSince1970: 2_000_000) }
    )
    let raw = ["private", " raw", " transcript"].joined()
    let delivered = ["private", " delivered", " text"].joined()
    let destination = ["com", ".example", ".writer"].joined()
    let record = DictationRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      createdAt: Date(timeIntervalSince1970: 1_999_900),
      rawTranscript: raw,
      deliveredText: delivered,
      destinationApplication: destination,
      cleanupChangedText: true,
      outcome: .cleaned,
      timings: .init(recognitionMilliseconds: 24, cleanupMilliseconds: 31, deliveryMilliseconds: 4)
    )

    try await store.save(record)

    #expect(try await store.records() == [record])
    let persistedBytes = try fixture.persistedBytes()
    #expect(!persistedBytes.contains(Data(raw.utf8)))
    #expect(!persistedBytes.contains(Data(delivered.utf8)))
    #expect(!persistedBytes.contains(Data(destination.utf8)))
  }

  @Test("History expires after 30 days and supports individual and bulk deletion")
  func retentionAndDeletion() async throws {
    let fixture = try Fixture()
    let now = Date(timeIntervalSince1970: 4_000_000)
    let store = try HistoryStore(
      directory: fixture.directory, keyProvider: InMemoryKeyProvider(), now: { now })
    let expired = makeRecord(id: 1, createdAt: now.addingTimeInterval(-30 * 86_400 - 1))
    let first = makeRecord(id: 2, createdAt: now.addingTimeInterval(-10))
    let second = makeRecord(id: 3, createdAt: now.addingTimeInterval(-5))
    try await store.save(expired)
    try await store.save(first)
    try await store.save(second)

    #expect(try await store.records().map(\.id) == [second.id, first.id])
    try await store.delete(first.id)
    #expect(try await store.records().map(\.id) == [second.id])
    try await store.clearHistory()
    #expect(try await store.records().isEmpty)
  }

  @Test(
    "Losing the installation key makes old history unreadable and reset creates a usable empty store"
  )
  func keyLossAndReset() async throws {
    let fixture = try Fixture()
    let provider = InMemoryKeyProvider()
    let store = try HistoryStore(directory: fixture.directory, keyProvider: provider)
    try await store.save(makeRecord(id: 4, createdAt: Date()))
    provider.replaceKey()

    await #expect(throws: PersistenceError.unreadableProtectedData) {
      _ = try await store.records()
    }

    try await store.resetProtectedData()
    #expect(try await store.records().isEmpty)
    try await store.save(makeRecord(id: 5, createdAt: Date()))
    #expect(try await store.records().count == 1)
  }

  @Test("Personal Vocabulary is encrypted and can be replaced or cleared")
  func encryptedVocabulary() async throws {
    let fixture = try Fixture()
    let store = try PersonalVocabularyStore(
      directory: fixture.directory, keyProvider: InMemoryKeyProvider())
    let terms = [["Play", "ground"].joined(), ["Pop", "tart"].joined()]

    try await store.replaceTerms(terms)

    #expect(try await store.terms() == terms)
    let persistedBytes = try fixture.persistedBytes()
    for term in terms {
      #expect(!persistedBytes.contains(Data(term.utf8)))
    }
    try await store.resetProtectedData()
    #expect(try await store.terms().isEmpty)
  }

  private func makeRecord(id: UInt8, createdAt: Date) -> DictationRecord {
    let uuid = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, id))
    return DictationRecord(
      id: uuid,
      createdAt: createdAt,
      rawTranscript: "raw-\(id)",
      deliveredText: "delivered-\(id)",
      destinationApplication: "destination-\(id)",
      cleanupChangedText: false,
      outcome: .rawTranscript,
      timings: .init(recognitionMilliseconds: 1, cleanupMilliseconds: 0, deliveryMilliseconds: 1)
    )
  }
}

private final class InMemoryKeyProvider: EncryptionKeyProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data(repeating: 7, count: 32)

  func encryptionKey() throws -> SymmetricKey {
    lock.withLock { SymmetricKey(data: bytes) }
  }

  func replaceKey() {
    lock.withLock { bytes = Data(repeating: 9, count: 32) }
  }

  func deleteKey() throws {
    replaceKey()
  }
}

private struct Fixture {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersistenceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func persistedBytes() throws -> Data {
    let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
    return try enumerator.compactMap { $0 as? URL }.reduce(into: Data()) { result, url in
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { return }
      result.append(try Data(contentsOf: url))
    }
  }
}
