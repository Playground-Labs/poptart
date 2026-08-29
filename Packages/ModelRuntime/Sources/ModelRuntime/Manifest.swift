import CryptoKit
import Foundation

public enum ModelRole: String, Codable, CaseIterable, Hashable, Sendable {
  case recognition
  case cleanup
}

public struct ModelLicense: Codable, Equatable, Sendable {
  public let name: String
  public let url: URL

  public init(name: String, url: URL) {
    self.name = name
    self.url = url
  }
}

public struct ModelArtifact: Codable, Equatable, Sendable {
  public let role: ModelRole
  public let url: URL
  public let relativePath: String
  public let byteSize: Int64
  public let sha256: String
  public let license: ModelLicense

  public init(
    role: ModelRole,
    url: URL,
    relativePath: String,
    byteSize: Int64,
    sha256: String,
    license: ModelLicense
  ) {
    self.role = role
    self.url = url
    self.relativePath = relativePath
    self.byteSize = byteSize
    self.sha256 = sha256
    self.license = license
  }
}

public struct ModelPackManifest: Codable, Equatable, Sendable {
  public let identity: String
  public let version: String
  public let minimumApplicationVersion: String
  public let maximumApplicationVersion: String
  /// The Cleanup token ceiling measured on a cold M1 for this pack release.
  public let cleanupTokenCeiling: Int
  public let artifacts: [ModelArtifact]

  private enum CodingKeys: String, CodingKey {
    case identity
    case version
    case minimumApplicationVersion
    case maximumApplicationVersion
    case cleanupTokenCeiling
    case artifacts
  }

  /// The measured Cleanup token ceiling is release evidence, so a manifest that omits it, nulls it,
  /// or declares a non-positive value cannot decode into an installable pack description.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.identity = try container.decode(String.self, forKey: .identity)
    self.version = try container.decode(String.self, forKey: .version)
    self.minimumApplicationVersion = try container.decode(
      String.self, forKey: .minimumApplicationVersion)
    self.maximumApplicationVersion = try container.decode(
      String.self, forKey: .maximumApplicationVersion)
    self.artifacts = try container.decode([ModelArtifact].self, forKey: .artifacts)
    guard let ceiling = try? container.decodeIfPresent(Int.self, forKey: .cleanupTokenCeiling),
      ceiling > 0
    else {
      throw ModelPackError.invalidCleanupTokenCeiling
    }
    self.cleanupTokenCeiling = ceiling
  }

  /// - Throws: `ModelPackError.invalidCleanupTokenCeiling` when the measured ceiling is not positive,
  ///   so no `ModelPackManifest` value can describe a pack without one.
  public init(
    identity: String,
    version: String,
    minimumApplicationVersion: String,
    maximumApplicationVersion: String,
    cleanupTokenCeiling: Int,
    artifacts: [ModelArtifact]
  ) throws {
    guard cleanupTokenCeiling > 0 else { throw ModelPackError.invalidCleanupTokenCeiling }
    self.identity = identity
    self.version = version
    self.minimumApplicationVersion = minimumApplicationVersion
    self.maximumApplicationVersion = maximumApplicationVersion
    self.cleanupTokenCeiling = cleanupTokenCeiling
    self.artifacts = artifacts
  }
}

/// The exact `manifest` bytes are signed; callers must not re-encode before verification.
public struct SignedModelPackManifest: Codable, Equatable, Sendable {
  public let manifest: Data
  public let signature: Data

  public init(manifest: Data, signature: Data) {
    self.manifest = manifest
    self.signature = signature
  }
}

public struct ModelPackManifestVerifier: Sendable {
  private let publicKey: Curve25519.Signing.PublicKey

  public init(publicKeyData: Data) throws {
    do {
      self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    } catch {
      throw ModelPackError.invalidPublicKey
    }
  }

  public func verify(_ signedData: Data) throws -> ModelPackManifest {
    let envelope: SignedModelPackManifest
    do {
      envelope = try JSONDecoder().decode(SignedModelPackManifest.self, from: signedData)
    } catch {
      throw ModelPackError.invalidManifest
    }
    guard publicKey.isValidSignature(envelope.signature, for: envelope.manifest) else {
      throw ModelPackError.invalidManifestSignature
    }
    do {
      return try JSONDecoder().decode(ModelPackManifest.self, from: envelope.manifest)
    } catch let error as ModelPackError {
      throw error
    } catch {
      throw ModelPackError.invalidManifest
    }
  }
}

public enum ModelPackError: Error, Equatable, Sendable {
  case invalidPublicKey
  case invalidManifest
  case invalidManifestSignature
  case invalidCleanupTokenCeiling
  case incompatibleApplicationVersion
  case downgradeNotAllowed
  case downloadFailed
  case incompleteDownload
  case downloadExceededExpectedSize
  case artifactSizeMismatch(ModelRole)
  case artifactHashMismatch(ModelRole)
  case smokeTestFailed
  case noPreviousPack
  case invalidActiveState
  case fileSystemFailure
}

struct SemanticVersion: Comparable, Sendable {
  let components: [Int]

  init?(_ value: String) {
    let core = value.split(separator: "-", maxSplits: 1)[0]
    let values = core.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
    guard values.count == core.split(separator: ".", omittingEmptySubsequences: false).count,
      values.count >= 2,
      values.allSatisfy({ $0 >= 0 })
    else { return nil }
    self.components = values
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }
}
