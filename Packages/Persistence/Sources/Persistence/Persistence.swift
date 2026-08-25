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
  case copiedToClipboard
  case emptyRecognition
  case cancelled
  case safetyStop
  case recordingFailure
  case deliveryFailure
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
  public let timings: DictationTimings

  public init(
    id: UUID,
    createdAt: Date,
    rawTranscript: String,
    deliveredText: String,
    destinationApplication: String,
    cleanupChangedText: Bool,
    outcome: DictationOutcome,
    timings: DictationTimings
  ) {
    self.id = id
    self.createdAt = createdAt
    self.rawTranscript = rawTranscript
    self.deliveredText = deliveredText
    self.destinationApplication = destinationApplication
    self.cleanupChangedText = cleanupChangedText
    self.outcome = outcome
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
    for url in try recordURLs() {
      let stored: StoredRecord
      do {
        stored = try decoder.decode(StoredRecord.self, from: Data(contentsOf: url))
      } catch {
        throw PersistenceError.invalidStoredData
      }
      if stored.metadata.createdAtMilliseconds < cutoffMilliseconds {
        try FileManager.default.removeItem(at: url)
        removed += 1
      }
    }
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
      return stored.metadata.record(with: protected)
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
  let outcome: DictationOutcome
  let timings: DictationTimings

  init(record: DictationRecord) {
    self.schemaVersion = 1
    self.id = record.id
    self.createdAtMilliseconds = Int64(record.createdAt.timeIntervalSince1970 * 1_000)
    self.cleanupChangedText = record.cleanupChangedText
    self.outcome = record.outcome
    self.timings = record.timings
  }

  func record(with protected: ProtectedRecord) -> DictationRecord {
    DictationRecord(
      id: id,
      createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1_000),
      rawTranscript: protected.rawTranscript,
      deliveredText: protected.deliveredText,
      destinationApplication: protected.destinationApplication,
      cleanupChangedText: cleanupChangedText,
      outcome: outcome,
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
