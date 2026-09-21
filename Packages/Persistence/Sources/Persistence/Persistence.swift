import CryptoKit
import Foundation
import Security

public enum PersistenceError: Error, Equatable, Sendable {
  case unreadableProtectedData
  case invalidStoredData
  case keychainFailure(OSStatus)
}

public protocol EncryptionKeyProviding: Sendable {
  func encryptionKey() throws -> SymmetricKey
  func deleteKey() throws
}

/// Stores one random, device-bound installation key in the macOS Keychain.
public struct KeychainEncryptionKeyProvider: EncryptionKeyProviding, Sendable {
  private let service: String
  private let account: String

  public init(service: String, account: String = "protected-local-data") {
    self.service = service
    self.account = account
  }

  public func encryptionKey() throws -> SymmetricKey {
    if let existing = try readKey() {
      return SymmetricKey(data: existing)
    }

    let newKey = SymmetricKey(size: .bits256)
    let bytes = newKey.withUnsafeBytes { Data($0) }
    var query = baseQuery
    query[kSecValueData as String] = bytes
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem, let racedKey = try readKey() {
      return SymmetricKey(data: racedKey)
    }
    guard status == errSecSuccess else {
      throw PersistenceError.keychainFailure(status)
    }
    return newKey
  }

  public func deleteKey() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PersistenceError.keychainFailure(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private func readKey() throws -> Data? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
      throw PersistenceError.keychainFailure(status)
    }
    guard let data = result as? Data, data.count == 32 else {
      throw PersistenceError.invalidStoredData
    }
    return data
  }
}

public enum DictationOutcome: String, Codable, CaseIterable, Sendable {
  case cleaned
  case rawTranscript
  case oversized
  case recognitionHypothesis
  case copiedTargetChanged
  case copiedNoTarget
  case emptyRecognition
  case cancelled
  /// Legacy records lost their delivery outcome; new records retain it alongside `recordingEnd`.
  case safetyStop
  case recordingFailure
  case deliveryFailure

  /// Dictation Records written before copying split in two stored `copiedToClipboard`. Every copy
  /// was shown as "the target changed" back then, and the two kinds were never distinguishable in
  /// those records, so that is what one becomes.
  init?(storedRawValue: String) {
    if storedRawValue == "copiedToClipboard" {
      self = .copiedTargetChanged
      return
    }
    guard let outcome = DictationOutcome(rawValue: storedRawValue) else { return nil }
    self = outcome
  }
}

/// Why a Dictation fell back to the Raw Transcript. Mirrors the dictation domain's reasons so a
/// Dictation Record can keep the reason without this package depending on that domain.
public enum RawTranscriptFallbackReason: String, Codable, CaseIterable, Sendable {
  case cleanupTimedOut
  case cleanupFailed
  case unsafeEditPlan
  case modelUnavailable
}

public enum DictationRecordingEnd: String, Codable, CaseIterable, Sendable {
  case released
  case fiveMinuteSafetyLimit
}

public enum DictationTextSource: String, Codable, CaseIterable, Sendable {
  case cleaned
  case rawTranscript
  case oversized
  case recognitionHypothesis
}

public struct DictationTimings: Codable, Equatable, Sendable {
  public let recognitionMilliseconds: Int
  public let cleanupMilliseconds: Int
  public let deliveryMilliseconds: Int

  public init(recognitionMilliseconds: Int, cleanupMilliseconds: Int, deliveryMilliseconds: Int) {
    self.recognitionMilliseconds = recognitionMilliseconds
    self.cleanupMilliseconds = cleanupMilliseconds
    self.deliveryMilliseconds = deliveryMilliseconds
  }
}

public struct DictationRecord: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let rawTranscript: String
  public let deliveredText: String
  public let destinationApplication: String
  public let cleanupChangedText: Bool
  public let outcome: DictationOutcome
  public let fallbackReason: RawTranscriptFallbackReason?
  /// Nil for older records that did not retain this dimension.
  public let recordingEnd: DictationRecordingEnd?
  public let textSource: DictationTextSource?
  public let timings: DictationTimings

  public init(
    id: UUID,
    createdAt: Date,
    rawTranscript: String,
    deliveredText: String,
    destinationApplication: String,
    cleanupChangedText: Bool,
    outcome: DictationOutcome,
    fallbackReason: RawTranscriptFallbackReason? = nil,
    recordingEnd: DictationRecordingEnd? = nil,
    textSource: DictationTextSource? = nil,
    timings: DictationTimings
  ) {
    self.id = id
    self.createdAt = createdAt
    self.rawTranscript = rawTranscript
    self.deliveredText = deliveredText
    self.destinationApplication = destinationApplication
    self.cleanupChangedText = cleanupChangedText
    self.outcome = outcome
    self.fallbackReason = fallbackReason
    self.recordingEnd = recordingEnd
    self.textSource = textSource
    self.timings = timings
  }
}

public actor HistoryStore {
  public static let retentionInterval: TimeInterval = 30 * 86_400

  private let recordsDirectory: URL
  private let keyProvider: any EncryptionKeyProviding
  private let now: @Sendable () -> Date
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  public init(
    directory: URL,
    keyProvider: any EncryptionKeyProviding,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    self.recordsDirectory = directory.appendingPathComponent("DictationRecords", isDirectory: true)
    self.keyProvider = keyProvider
    self.now = now
    self.encoder = Self.makeEncoder()
    try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
  }

  public func save(_ record: DictationRecord) throws {
    _ = try? expireRecords()
    let metadata = RecordMetadata(record: record)
    let protected = ProtectedRecord(record: record)
    let aad = try encoder.encode(metadata)
    let plaintext = try encoder.encode(protected)
    let ciphertext = try seal(plaintext, authenticating: aad, key: keyProvider.encryptionKey())
    let stored = StoredRecord(metadata: metadata, encryptedPayload: ciphertext)
    try encoder.encode(stored).write(to: fileURL(for: record.id), options: [.atomic])
  }

  public func records() throws -> [DictationRecord] {
    try expireRecords()
    return try recordURLs().map(load).sorted { $0.createdAt > $1.createdAt }
  }

  /// Keeps retention active even while History is closed. Storage failures retry at the next wake.
  public func maintainRetention(
    sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(60)) }
  ) async {
    // ponytail: expiry can lag by one minute while running; use per-record timers if tighter timing is needed.
    while !Task.isCancelled {
      _ = try? expireRecords()
      do { try await sleep() } catch { return }
    }
  }

  public func delete(_ id: UUID) throws {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  public func clearHistory() throws {
    for url in try recordURLs() {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// Removes data that cannot be decrypted after a Keychain reset or key loss.
  public func resetProtectedData() throws {
    try clearHistory()
  }

  @discardableResult
  public func expireRecords() throws -> Int {
    let cutoffMilliseconds = Int64((now().timeIntervalSince1970 - Self.retentionInterval) * 1_000)
    var removed = 0
    var firstError: (any Error)?
    for url in try recordURLs() {
      do {
        let stored = try decoder.decode(StoredRecord.self, from: Data(contentsOf: url))
        if stored.metadata.createdAtMilliseconds < cutoffMilliseconds {
          try FileManager.default.removeItem(at: url)
          removed += 1
        }
      } catch {
        firstError = firstError ?? PersistenceError.invalidStoredData
      }
    }
    if let firstError { throw firstError }
    return removed
  }

  private func load(from url: URL) throws -> DictationRecord {
    let stored: StoredRecord
    do {
      stored = try decoder.decode(StoredRecord.self, from: Data(contentsOf: url))
    } catch {
      throw PersistenceError.invalidStoredData
    }
    do {
      let aad = try encoder.encode(stored.metadata)
      let plaintext = try open(
        stored.encryptedPayload, authenticating: aad, key: keyProvider.encryptionKey())
      let protected = try decoder.decode(ProtectedRecord.self, from: plaintext)
      return try stored.metadata.record(with: protected)
    } catch let error as PersistenceError {
      throw error
    } catch {
      throw PersistenceError.unreadableProtectedData
    }
  }

  private func recordURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: recordsDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "poptartrecord" }
  }

  private func fileURL(for id: UUID) -> URL {
    recordsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("poptartrecord")
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

public actor PersonalVocabularyStore {
  private let fileURL: URL
  private let keyProvider: any EncryptionKeyProviding

  public init(directory: URL, keyProvider: any EncryptionKeyProviding) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.fileURL = directory.appendingPathComponent("PersonalVocabulary.protected")
    self.keyProvider = keyProvider
  }

  public func terms() throws -> [String] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let protected = try Data(contentsOf: fileURL)
      let plaintext = try open(
        protected, authenticating: vocabularyAAD, key: keyProvider.encryptionKey())
      return try JSONDecoder().decode([String].self, from: plaintext)
    } catch let error as PersistenceError {
      throw error
    } catch {
      throw PersistenceError.unreadableProtectedData
    }
  }

  public func replaceTerms(_ terms: [String]) throws {
    let plaintext = try JSONEncoder().encode(terms)
    let protected = try seal(
      plaintext, authenticating: vocabularyAAD, key: keyProvider.encryptionKey())
    try protected.write(to: fileURL, options: [.atomic])
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }

  /// Removes vocabulary that can no longer be decrypted after installation-key loss.
  public func resetProtectedData() throws {
    try clear()
  }
}

private struct RecordMetadata: Codable {
  let schemaVersion: Int
  let id: UUID
  let createdAtMilliseconds: Int64
  let cleanupChangedText: Bool
  /// The outcome as the raw string it was stored as, not as a `DictationOutcome`, so re-encoding
  /// this metadata reproduces the exact bytes it was sealed against even when the stored raw value
  /// is one this build no longer writes.
  let outcome: String
  /// Absent, not null, when there is no reason, so Dictation Records written before this field
  /// existed still authenticate against the metadata they were sealed with. Stored as the raw
  /// string for the same reason `outcome` is; a reason this build does not know reads back as none.
  let fallbackReason: String?
  // Optional raw strings preserve the exact authenticated bytes of older metadata.
  let recordingEnd: String?
  let textSource: String?
  let timings: DictationTimings

  init(record: DictationRecord) {
    self.schemaVersion = 1
    self.id = record.id
    self.createdAtMilliseconds = Int64(record.createdAt.timeIntervalSince1970 * 1_000)
    self.cleanupChangedText = record.cleanupChangedText
    self.outcome = record.outcome.rawValue
    self.fallbackReason = record.fallbackReason?.rawValue
    self.recordingEnd = record.recordingEnd?.rawValue
    self.textSource = record.textSource?.rawValue
    self.timings = record.timings
  }

  func record(with protected: ProtectedRecord) throws -> DictationRecord {
    guard let outcome = DictationOutcome(storedRawValue: outcome) else {
      throw PersistenceError.invalidStoredData
    }
    return DictationRecord(
      id: id,
      createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000),
      rawTranscript: protected.rawTranscript,
      deliveredText: protected.deliveredText,
      destinationApplication: protected.destinationApplication,
      cleanupChangedText: cleanupChangedText,
      outcome: outcome,
      fallbackReason: fallbackReason.flatMap(RawTranscriptFallbackReason.init(rawValue:)),
      recordingEnd: recordingEnd.flatMap(DictationRecordingEnd.init(rawValue:)),
      textSource: textSource.flatMap(DictationTextSource.init(rawValue:)),
      timings: timings
    )
  }
}

private struct ProtectedRecord: Codable {
  let rawTranscript: String
  let deliveredText: String
  let destinationApplication: String

  init(record: DictationRecord) {
    self.rawTranscript = record.rawTranscript
    self.deliveredText = record.deliveredText
    self.destinationApplication = record.destinationApplication
  }
}

private struct StoredRecord: Codable {
  let metadata: RecordMetadata
  let encryptedPayload: Data
}

private let vocabularyAAD = Data("Poptart.PersonalVocabulary.v1".utf8)

private func seal(_ plaintext: Data, authenticating aad: Data, key: SymmetricKey) throws -> Data {
  do {
    let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
    guard let combined = box.combined else { throw PersistenceError.invalidStoredData }
    return combined
  } catch let error as PersistenceError {
    throw error
  } catch {
    throw PersistenceError.unreadableProtectedData
  }
}

private func open(_ protected: Data, authenticating aad: Data, key: SymmetricKey) throws -> Data {
  do {
    let box = try AES.GCM.SealedBox(combined: protected)
    return try AES.GCM.open(box, using: key, authenticating: aad)
  } catch {
    throw PersistenceError.unreadableProtectedData
  }
}
