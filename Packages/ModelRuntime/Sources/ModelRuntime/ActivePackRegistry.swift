import CryptoKit
import Foundation

/// Read-only startup access to the pack atomically activated by `ModelPackInstaller`.
public struct InstalledModelPackRegistry: Sendable {
  private let rootDirectory: URL
  private let manifestPublicKey: Data
  private let applicationVersion: SemanticVersion

  public init(rootDirectory: URL, applicationVersion: String, manifestPublicKey: Data) throws {
    guard let applicationVersion = SemanticVersion(applicationVersion) else {
      throw ModelPackError.incompatibleApplicationVersion
    }
    self.rootDirectory = rootDirectory.standardizedFileURL
    self.manifestPublicKey = manifestPublicKey
    self.applicationVersion = applicationVersion
  }

  public func activePack() throws -> InstalledModelPack? {
    let stateURL = rootDirectory.appendingPathComponent("active-model-pack.json")
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
    let state: ActiveModelPackState
    do {
      state = try JSONDecoder().decode(ActiveModelPackState.self, from: Data(contentsOf: stateURL))
    } catch let error as ModelPackError {
      throw error
    } catch {
      throw ModelPackError.invalidActiveState
    }

    let authenticated = try ModelPackManifestVerifier(publicKeyData: manifestPublicKey)
      .verify(state.signedManifest)
    guard authenticated == state.current.manifest else { throw ModelPackError.invalidActiveState }
    guard let minimum = SemanticVersion(authenticated.minimumApplicationVersion),
      let maximum = SemanticVersion(authenticated.maximumApplicationVersion), minimum <= maximum
    else { throw ModelPackError.invalidManifest }
    guard (minimum...maximum).contains(applicationVersion) else {
      throw ModelPackError.incompatibleApplicationVersion
    }

    let packs = rootDirectory.appendingPathComponent("packs", isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let directory = state.current.directory.standardizedFileURL.resolvingSymlinksInPath()
    guard directory.deletingLastPathComponent() == packs,
      FileManager.default.fileExists(atPath: directory.path)
    else { throw ModelPackError.invalidActiveState }

    try verifyModelPackInventory(state.current.manifest, at: directory)
    for artifact in state.current.manifest.artifacts {
      let artifactURL = directory.appendingPathComponent(artifact.relativePath)
        .standardizedFileURL.resolvingSymlinksInPath()
      guard artifactURL.path.hasPrefix(directory.path + "/") else {
        throw ModelPackError.invalidActiveState
      }
      let attributes = try? FileManager.default.attributesOfItem(atPath: artifactURL.path)
      guard (attributes?[.size] as? NSNumber)?.int64Value == artifact.byteSize else {
        throw ModelPackError.artifactSizeMismatch(artifact.role)
      }
      guard try sha256(of: artifactURL) == artifact.sha256.lowercased() else {
        throw ModelPackError.artifactHashMismatch(artifact.role)
      }
    }
    return state.current
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Model loaders discover files and layout directories, so both must match the signed inventory.
func verifyModelPackInventory(_ manifest: ModelPackManifest, at directory: URL, allowIncomplete: Bool = false) throws {
  let expectedFiles = Set(manifest.artifacts.map(\.relativePath))
  let allowedFiles = allowIncomplete ? expectedFiles.union(expectedFiles.map { $0 + ".partial" }) : expectedFiles
  var expectedDirectories = Set<String>()
  for path in expectedFiles {
    let components = path.split(separator: "/")
    guard !components.isEmpty, components.joined(separator: "/") == path,
      components.allSatisfy({ $0 != "." && $0 != ".." }) else {
      throw ModelPackError.artifactInventoryMismatch
    }
    for count in 1..<components.count {
      expectedDirectories.insert(components.prefix(count).joined(separator: "/"))
    }
  }
  var pending = [(directory, "")]
  var files = Set<String>()
  while let (folder, prefix) = pending.popLast() {
    for url in try FileManager.default.contentsOfDirectory(at: folder,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) {
      let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
      let path = prefix.isEmpty ? url.lastPathComponent : prefix + "/" + url.lastPathComponent
      guard attributes.isSymbolicLink != true else { throw ModelPackError.artifactInventoryMismatch }
      if attributes.isDirectory == true {
        guard expectedDirectories.contains(path) else { throw ModelPackError.artifactInventoryMismatch }
        pending.append((url, path))
      } else {
        guard attributes.isRegularFile == true, allowedFiles.contains(path) else {
          throw ModelPackError.artifactInventoryMismatch
        }
        files.insert(path)
      }
    }
  }
  guard allowIncomplete || files == expectedFiles else { throw ModelPackError.artifactInventoryMismatch }
}
