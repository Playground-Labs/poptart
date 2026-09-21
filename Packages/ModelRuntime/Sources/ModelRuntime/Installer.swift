import CryptoKit
import Foundation

public enum ExplicitModelPackAction: String, Sendable {
  case onboardingInstall
  case update
  case repair
}

public struct ResumableDownloadRequest: Equatable, Sendable {
  public let source: URL
  public let destination: URL
  public let resumeOffset: Int64
  public let expectedSize: Int64

  public init(source: URL, destination: URL, resumeOffset: Int64, expectedSize: Int64) {
    self.source = source
    self.destination = destination
    self.resumeOffset = resumeOffset
    self.expectedSize = expectedSize
  }
}

public struct ResumableDownloadResult: Equatable, Sendable {
  public let bytesStored: Int64
  public let isComplete: Bool

  public init(bytesStored: Int64, isComplete: Bool) {
    self.bytesStored = bytesStored
    self.isComplete = isComplete
  }
}

public protocol ResumableArtifactDownloading: Sendable {
  /// Writes to `request.destination`, preserving a partial file if the operation is interrupted.
  func download(_ request: ResumableDownloadRequest) async throws -> ResumableDownloadResult
}

public protocol ModelPackSmokeTesting: Sendable {
  func validate(packAt directory: URL, manifest: ModelPackManifest) async throws
}

public struct InstalledModelPack: Codable, Equatable, Sendable {
  public let directory: URL
  public let manifest: ModelPackManifest

  /// The measured Cleanup token ceiling this pack ships; never a user setting or an app default.
  public var cleanupTokenCeiling: Int { manifest.cleanupTokenCeiling }

  public init(directory: URL, manifest: ModelPackManifest) {
    self.directory = directory
    self.manifest = manifest
  }
}

struct ActiveModelPackState: Codable, Sendable {
  var current: InstalledModelPack
  let signedManifest: Data
}

private struct RetainedSignedManifest: Decodable {
  let signedManifest: Data
}

/// The only production entry point that can reach the download boundary. Every operation requires
/// an explicit user-action classification and no timer or startup hook exists in this module.
public actor ModelPackInstaller {
  private let rootDirectory: URL
  private let stagingDirectory: URL
  private let packsDirectory: URL
  private let activeStateURL: URL
  private let applicationVersion: SemanticVersion
  private let verifier: ModelPackManifestVerifier
  private let downloader: any ResumableArtifactDownloading
  private let smokeTester: any ModelPackSmokeTesting
  private var state: ActiveModelPackState?
  private var downgradeFloor: SemanticVersion?
  private var isInstalling = false

  public init(
    rootDirectory: URL,
    applicationVersion: String,
    manifestPublicKey: Data,
    downloader: any ResumableArtifactDownloading,
    smokeTester: any ModelPackSmokeTesting
  ) throws {
    guard let applicationVersion = SemanticVersion(applicationVersion) else {
      throw ModelPackError.incompatibleApplicationVersion
    }
    self.rootDirectory = rootDirectory
    self.stagingDirectory = rootDirectory.appendingPathComponent("staging", isDirectory: true)
    self.packsDirectory = rootDirectory.appendingPathComponent("packs", isDirectory: true)
    self.activeStateURL = rootDirectory.appendingPathComponent("active-model-pack.json")
    self.applicationVersion = applicationVersion
    self.verifier = try ModelPackManifestVerifier(publicKeyData: manifestPublicKey)
    self.downloader = downloader
    self.smokeTester = smokeTester

    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: activeStateURL.path) {
      do {
        let data = try Data(contentsOf: activeStateURL)
        let retained = try JSONDecoder().decode(RetainedSignedManifest.self, from: data)
        let authenticated = try verifier.verify(retained.signedManifest)
        guard let version = SemanticVersion(authenticated.version) else {
          throw ModelPackError.unrecoverableActiveState
        }
        self.downgradeFloor = version
        // Mutable metadata may be unusable while the publisher-signed version remains trustworthy.
        // Keep Repair available without forgetting the authenticated downgrade floor.
        if let decoded = try? JSONDecoder().decode(ActiveModelPackState.self, from: data),
          decoded.current.manifest == authenticated {
          self.state = decoded
        }
      } catch {
        throw ModelPackError.unrecoverableActiveState
      }
    }
  }

  public func activePack() -> InstalledModelPack? { state?.current }

  @discardableResult
  public func perform(
    _ action: ExplicitModelPackAction,
    signedManifest: Data
  ) async throws -> InstalledModelPack {
    guard !isInstalling else { throw ModelPackError.installationInProgress }
    isInstalling = true
    defer { isInstalling = false }
    let manifest = try verifier.verify(signedManifest)
    try validate(manifest, for: action)

    let stage = stagingDirectory.appendingPathComponent(
      "\(manifest.identity)-\(manifest.version)", isDirectory: true)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

    do {
      // Interrupted staging may contain listed files and their partials, but no unsigned paths.
      try verifyModelPackInventory(manifest, at: stage, allowIncomplete: true)
      for artifact in manifest.artifacts {
        try await stageArtifact(artifact, in: stage)
      }
      try verifyModelPackInventory(manifest, at: stage)
      do {
        try await smokeTester.validate(packAt: stage, manifest: manifest)
      } catch {
        try? FileManager.default.removeItem(at: stage)
        throw ModelPackError.smokeTestFailed
      }

      let installedDirectory = packsDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      try FileManager.default.moveItem(at: stage, to: installedDirectory)
      let installed = InstalledModelPack(directory: installedDirectory, manifest: manifest)
      let newState = ActiveModelPackState(current: installed, signedManifest: signedManifest)
      try persist(newState)
      state = newState
      downgradeFloor = SemanticVersion(manifest.version)
      return installed
    } catch let error as ModelPackError {
      switch error {
      case .artifactInventoryMismatch, .artifactSizeMismatch, .artifactHashMismatch:
        try? FileManager.default.removeItem(at: stage)
      default: break
      }
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ModelPackError.fileSystemFailure
    }
  }

  private func stageArtifact(_ artifact: ModelArtifact, in stage: URL) async throws {
    let finalURL = stage.appendingPathComponent(artifact.relativePath)
    let partialURL = finalURL.appendingPathExtension("partial")
    try FileManager.default.createDirectory(
      at: finalURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: finalURL.path) {
      try verifyArtifact(artifact, at: finalURL)
      return
    }

    var resumeOffset = fileSize(at: partialURL)
    if resumeOffset > artifact.byteSize {
      try FileManager.default.removeItem(at: partialURL)
      resumeOffset = 0
    }
    // A transfer may have stored every byte before interruption. Verify it below rather than
    // requesting a Range starting at EOF, which a server can only reject.
    if resumeOffset < artifact.byteSize {
      let result: ResumableDownloadResult
      do {
        result = try await downloader.download(
          .init(
            source: artifact.url,
            destination: partialURL,
            resumeOffset: resumeOffset,
            expectedSize: artifact.byteSize
          ))
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ModelPackError {
        throw error
      } catch {
        throw ModelPackError.downloadFailed
      }
      guard result.isComplete else { throw ModelPackError.incompleteDownload }
    }

    try verifyArtifact(artifact, at: partialURL)
    try FileManager.default.moveItem(at: partialURL, to: finalURL)
  }

  private func verifyArtifact(_ artifact: ModelArtifact, at url: URL) throws {
    guard fileSize(at: url) == artifact.byteSize else {
      throw ModelPackError.artifactSizeMismatch(artifact.role)
    }
    guard try sha256(of: url) == artifact.sha256.lowercased() else {
      throw ModelPackError.artifactHashMismatch(artifact.role)
    }
  }

  private func validate(_ manifest: ModelPackManifest, for _: ExplicitModelPackAction) throws {
    let artifactPaths = manifest.artifacts.map(\.relativePath)
    guard isSafeComponent(manifest.identity),
      SemanticVersion(manifest.version) != nil,
      let minimum = SemanticVersion(manifest.minimumApplicationVersion),
      let maximum = SemanticVersion(manifest.maximumApplicationVersion),
      minimum <= maximum,
      Set(manifest.artifacts.map(\.role)) == Set(ModelRole.allCases),
      Set(artifactPaths).count == artifactPaths.count,
      manifest.artifacts.allSatisfy(isValid)
    else {
      throw ModelPackError.invalidManifest
    }
    guard (minimum...maximum).contains(applicationVersion) else {
      throw ModelPackError.incompatibleApplicationVersion
    }
    if let activeVersion = downgradeFloor,
      let proposedVersion = SemanticVersion(manifest.version),
      proposedVersion < activeVersion
    {
      throw ModelPackError.downgradeNotAllowed
    }
  }

  private func isValid(_ artifact: ModelArtifact) -> Bool {
    let components = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: false)
    let hashCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    return !artifact.relativePath.hasPrefix("/")
      && !components.isEmpty
      && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
      && artifact.byteSize > 0
      && artifact.sha256.count == 64
      && artifact.sha256.unicodeScalars.allSatisfy(hashCharacters.contains)
      && !artifact.license.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && artifact.license.url.scheme == "https"
      && (artifact.url.scheme == "https"
        || (artifact.url.scheme == "http" && artifact.url.host == "localhost"))
  }

  private func isSafeComponent(_ value: String) -> Bool {
    !value.isEmpty
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
      }
  }

  private func persist(_ state: ActiveModelPackState) throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(state).write(to: activeStateURL, options: [.atomic])
    } catch {
      throw ModelPackError.fileSystemFailure
    }
  }

  private func fileSize(at url: URL) -> Int64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else { return 0 }
    return size.int64Value
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while autoreleasepool(invoking: {
      let chunk = try? handle.read(upToCount: 1_048_576)
      guard let chunk, !chunk.isEmpty else { return false }
      digest.update(data: chunk)
      return true
    }) {}
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
