import CryptoKit
import Foundation

/// Read-only startup access to the pack atomically activated by `ModelPackInstaller`.
public struct InstalledModelPackRegistry: Sendable {
  private struct ActiveState: Codable {
    let current: InstalledModelPack
    let previous: InstalledModelPack?
  }

  private let rootDirectory: URL

  public init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory.standardizedFileURL
  }

  public func activePack() throws -> InstalledModelPack? {
    let stateURL = rootDirectory.appendingPathComponent("active-model-pack.json")
    guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
    let state: ActiveState
    do {
      state = try JSONDecoder().decode(ActiveState.self, from: Data(contentsOf: stateURL))
    } catch {
      throw ModelPackError.invalidActiveState
    }

    let packs = rootDirectory.appendingPathComponent("packs", isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let directory = state.current.directory.standardizedFileURL.resolvingSymlinksInPath()
    guard directory.deletingLastPathComponent() == packs,
      FileManager.default.fileExists(atPath: directory.path)
    else { throw ModelPackError.invalidActiveState }

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
