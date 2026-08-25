import CryptoKit
import Foundation
import Testing

@testable import ModelRuntime

@Suite("Signed atomic Model Pack lifecycle")
struct ModelPackInstallerTests {
  @Test(
    "An explicit onboarding action verifies, downloads, stages, smoke-tests, and activates one complete Model Pack"
  )
  func installsCompletePack() async throws {
    let fixture = try ModelFixture()
    let recognition = Data([1, 2, 3, 4])
    let cleanup = Data([5, 6, 7])
    let signed = try fixture.signedManifest(
      version: "1.0.0",
      artifacts: [
        fixture.artifact(.recognition, path: "recognition/model.bin", data: recognition),
        fixture.artifact(.cleanup, path: "cleanup/model.bin", data: cleanup),
      ])
    let downloader = FakeDownloader(content: [
      "https://models.example/recognition": recognition,
      "https://models.example/cleanup": cleanup,
    ])
    let smokeTester = FakeSmokeTester()
    let installer = try ModelPackInstaller(
      rootDirectory: fixture.directory,
      applicationVersion: "1.0.0",
      manifestPublicKey: fixture.publicKey,
      downloader: downloader,
      smokeTester: smokeTester
    )

    let installed = try await installer.perform(.onboardingInstall, signedManifest: signed)

    #expect(installed.manifest.version == "1.0.0")
    #expect(
      try Data(contentsOf: installed.directory.appendingPathComponent("recognition/model.bin"))
        == recognition)
    #expect(
      try Data(contentsOf: installed.directory.appendingPathComponent("cleanup/model.bin"))
        == cleanup)
    #expect(await installer.activePack() == installed)
    #expect(await smokeTester.testedVersions() == ["1.0.0"])
    #expect(await downloader.requests().map(\.resumeOffset) == [0, 0])
    #expect(try InstalledModelPackRegistry(rootDirectory: fixture.directory).activePack() == installed)
  }

  @Test("A bad manifest signature is rejected before the download boundary")
  func rejectsBadSignatureWithoutNetworkAccess() async throws {
    let fixture = try ModelFixture()
    let data = Data([1])
    let valid = try fixture.signedManifest(
      version: "1.0.0", artifacts: fixture.completeArtifacts(recognition: data, cleanup: data))
    var envelope = try JSONDecoder().decode(SignedModelPackManifest.self, from: valid)
    var badSignature = envelope.signature
    badSignature[0] ^= 0xff
    envelope = SignedModelPackManifest(manifest: envelope.manifest, signature: badSignature)
    let downloader = FakeDownloader(content: [:])
    let installer = try fixture.installer(downloader: downloader)

    await #expect(throws: ModelPackError.invalidManifestSignature) {
      try await installer.perform(
        .onboardingInstall, signedManifest: JSONEncoder().encode(envelope))
    }
    #expect(await downloader.requests().isEmpty)
  }

  @Test("An interrupted artifact resumes from the persisted byte offset")
  func resumesInterruptedArtifact() async throws {
    let fixture = try ModelFixture()
    let recognition = Data([1, 2, 3, 4, 5])
    let cleanup = Data([6, 7])
    let signed = try fixture.signedManifest(
      version: "1.0.0",
      artifacts: fixture.completeArtifacts(recognition: recognition, cleanup: cleanup)
    )
    let downloader = InterruptOnceDownloader(content: [
      "https://models.example/recognition": recognition,
      "https://models.example/cleanup": cleanup,
    ])
    let installer = try fixture.installer(downloader: downloader)

    await #expect(throws: ModelPackError.downloadFailed) {
      try await installer.perform(.onboardingInstall, signedManifest: signed)
    }
    _ = try await installer.perform(.onboardingInstall, signedManifest: signed)

    #expect(await downloader.offsets() == [0, 2, 0])
  }

  @Test("A failed smoke test preserves the active pack, while activation supports rollback")
  func atomicActivationAndRollback() async throws {
    let fixture = try ModelFixture()
    let v1Data = Data([1, 1])
    let v2Data = Data([2, 2, 2])
    let v1 = try fixture.signedManifest(
      version: "1.0.0", artifacts: fixture.completeArtifacts(recognition: v1Data, cleanup: v1Data))
    let v2 = try fixture.signedManifest(
      version: "1.1.0", artifacts: fixture.completeArtifacts(recognition: v2Data, cleanup: v2Data))
    let downloader = FakeDownloader(content: [
      "https://models.example/recognition": v1Data,
      "https://models.example/cleanup": v1Data,
    ])
    let smokeTester = FakeSmokeTester()
    let installer = try fixture.installer(downloader: downloader, smokeTester: smokeTester)
    let first = try await installer.perform(.onboardingInstall, signedManifest: v1)

    await downloader.replaceContent([
      "https://models.example/recognition": v2Data,
      "https://models.example/cleanup": v2Data,
    ])
    await smokeTester.fail(version: "1.1.0")
    await #expect(throws: ModelPackError.smokeTestFailed) {
      try await installer.perform(.update, signedManifest: v2)
    }
    #expect(await installer.activePack() == first)

    await smokeTester.allowAll()
    let second = try await installer.perform(.update, signedManifest: v2)
    #expect(await installer.activePack() == second)
    #expect(try await installer.rollback() == first)
    #expect(await installer.activePack() == first)
  }

  @Test("Incompatible and downgrade manifests are rejected before downloading")
  func rejectsCompatibilityAndDowngrade() async throws {
    let fixture = try ModelFixture()
    let data = Data([8])
    let artifacts = fixture.completeArtifacts(recognition: data, cleanup: data)
    let downloader = FakeDownloader(content: [
      "https://models.example/recognition": data,
      "https://models.example/cleanup": data,
    ])
    let installer = try fixture.installer(downloader: downloader)
    let current = try fixture.signedManifest(version: "1.1.0", artifacts: artifacts)
    _ = try await installer.perform(.onboardingInstall, signedManifest: current)
    let requestCount = await downloader.requests().count
    let old = try fixture.signedManifest(version: "1.0.0", artifacts: artifacts)

    await #expect(throws: ModelPackError.downgradeNotAllowed) {
      try await installer.perform(.update, signedManifest: old)
    }
    #expect(await downloader.requests().count == requestCount)

    let incompatible = try fixture.signedManifest(
      version: "1.2.0",
      minimumApplicationVersion: "2.0.0",
      maximumApplicationVersion: "2.9.0",
      artifacts: artifacts
    )
    await #expect(throws: ModelPackError.incompatibleApplicationVersion) {
      try await installer.perform(.update, signedManifest: incompatible)
    }
    #expect(await downloader.requests().count == requestCount)
  }

  @Test("A same-size artifact with the wrong hash is discarded without activation")
  func rejectsHashMismatch() async throws {
    let fixture = try ModelFixture()
    let expected = Data([1, 2, 3])
    let corrupted = Data([3, 2, 1])
    let signed = try fixture.signedManifest(
      version: "1.0.0",
      artifacts: fixture.completeArtifacts(recognition: expected, cleanup: expected)
    )
    let downloader = FakeDownloader(content: [
      "https://models.example/recognition": corrupted,
      "https://models.example/cleanup": expected,
    ])
    let installer = try fixture.installer(downloader: downloader)

    await #expect(throws: ModelPackError.artifactHashMismatch(.recognition)) {
      try await installer.perform(.onboardingInstall, signedManifest: signed)
    }
    #expect(await installer.activePack() == nil)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: fixture.directory.appendingPathComponent("staging"),
        includingPropertiesForKeys: nil
      ).isEmpty)
  }

  @Test("Unsafe artifact paths are rejected before the download boundary")
  func rejectsUnsafeArtifactPath() async throws {
    let fixture = try ModelFixture()
    let data = Data([1])
    let artifacts = [
      fixture.artifact(.recognition, path: "../outside.bin", data: data),
      fixture.artifact(.cleanup, path: "cleanup/model.bin", data: data),
    ]
    let signed = try fixture.signedManifest(version: "1.0.0", artifacts: artifacts)
    let downloader = FakeDownloader(content: [:])
    let installer = try fixture.installer(downloader: downloader)

    await #expect(throws: ModelPackError.invalidManifest) {
      try await installer.perform(.onboardingInstall, signedManifest: signed)
    }
    #expect(await downloader.requests().isEmpty)
  }

  @Test("A Model Pack stages and verifies every file across multi-file model directories")
  func installsMultipleArtifactsPerRole() async throws {
    let fixture = try ModelFixture()
    let recognitionModel = Data([1, 2])
    let recognitionTokenizer = Data([3, 4, 5])
    let cleanupModel = Data([6, 7, 8])
    let cleanupTokenizer = Data([9])
    let artifacts = [
      fixture.artifact(
        .recognition, path: "recognition/model.bin", data: recognitionModel,
        sourceName: "recognition-model"),
      fixture.artifact(
        .recognition, path: "recognition/tokenizer.json", data: recognitionTokenizer,
        sourceName: "recognition-tokenizer"),
      fixture.artifact(
        .cleanup, path: "cleanup/model.bin", data: cleanupModel,
        sourceName: "cleanup-model"),
      fixture.artifact(
        .cleanup, path: "cleanup/tokenizer.json", data: cleanupTokenizer,
        sourceName: "cleanup-tokenizer"),
    ]
    let signed = try fixture.signedManifest(version: "1.0.0", artifacts: artifacts)
    let downloader = FakeDownloader(content: [
      "https://models.example/recognition-model": recognitionModel,
      "https://models.example/recognition-tokenizer": recognitionTokenizer,
      "https://models.example/cleanup-model": cleanupModel,
      "https://models.example/cleanup-tokenizer": cleanupTokenizer,
    ])
    let installer = try fixture.installer(downloader: downloader)

    let installed = try await installer.perform(.onboardingInstall, signedManifest: signed)

    #expect(installed.manifest.artifacts.count == 4)
    for artifact in artifacts {
      let stored = try Data(
        contentsOf: installed.directory.appendingPathComponent(artifact.relativePath))
      #expect(
        SHA256.hash(data: stored).map { String(format: "%02x", $0) }.joined() == artifact.sha256)
    }
    #expect(await downloader.requests().count == 4)
  }

  @Test("Duplicate artifact paths are rejected before the download boundary")
  func rejectsDuplicateArtifactPaths() async throws {
    let fixture = try ModelFixture()
    let data = Data([1])
    let artifacts = [
      fixture.artifact(.recognition, path: "shared/model.bin", data: data),
      fixture.artifact(.cleanup, path: "shared/model.bin", data: data),
    ]
    let signed = try fixture.signedManifest(version: "1.0.0", artifacts: artifacts)
    let downloader = FakeDownloader(content: [:])
    let installer = try fixture.installer(downloader: downloader)

    await #expect(throws: ModelPackError.invalidManifest) {
      try await installer.perform(.onboardingInstall, signedManifest: signed)
    }
    #expect(await downloader.requests().isEmpty)
  }
}

private struct ModelFixture {
  let directory: URL
  let privateKey = Curve25519.Signing.PrivateKey()
  var publicKey: Data { privateKey.publicKey.rawRepresentation }

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func artifact(
    _ role: ModelRole, path: String, data: Data, sourceName: String? = nil
  ) -> ModelArtifact {
    ModelArtifact(
      role: role,
      url: URL(string: "https://models.example/\(sourceName ?? role.rawValue)")!,
      relativePath: path,
      byteSize: Int64(data.count),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      license: .init(
        name: "Apache-2.0", url: URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!)
    )
  }

  func completeArtifacts(recognition: Data, cleanup: Data) -> [ModelArtifact] {
    [
      artifact(.recognition, path: "recognition/model.bin", data: recognition),
      artifact(.cleanup, path: "cleanup/model.bin", data: cleanup),
    ]
  }

  func signedManifest(
    version: String,
    minimumApplicationVersion: String = "1.0.0",
    maximumApplicationVersion: String = "1.9.9",
    artifacts: [ModelArtifact]
  ) throws -> Data {
    let manifest = ModelPackManifest(
      identity: "poptart-english",
      version: version,
      minimumApplicationVersion: minimumApplicationVersion,
      maximumApplicationVersion: maximumApplicationVersion,
      cleanupTokenCeiling: 384,
      artifacts: artifacts
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let manifestData = try encoder.encode(manifest)
    let signature = try privateKey.signature(for: manifestData)
    return try encoder.encode(SignedModelPackManifest(manifest: manifestData, signature: signature))
  }

  func installer(
    downloader: any ResumableArtifactDownloading,
    smokeTester: any ModelPackSmokeTesting = FakeSmokeTester()
  ) throws -> ModelPackInstaller {
    try ModelPackInstaller(
      rootDirectory: directory,
      applicationVersion: "1.0.0",
      manifestPublicKey: publicKey,
      downloader: downloader,
      smokeTester: smokeTester
    )
  }
}

private actor FakeDownloader: ResumableArtifactDownloading {
  private var content: [String: Data]
  private var received: [ResumableDownloadRequest] = []

  init(content: [String: Data]) { self.content = content }

  func download(_ request: ResumableDownloadRequest) async throws -> ResumableDownloadResult {
    received.append(request)
    guard let data = content[request.source.absoluteString] else {
      throw ModelPackError.downloadFailed
    }
    let suffix = data.dropFirst(Int(request.resumeOffset))
    if !FileManager.default.fileExists(atPath: request.destination.path) {
      FileManager.default.createFile(atPath: request.destination.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: request.destination)
    try handle.seekToEnd()
    try handle.write(contentsOf: suffix)
    try handle.close()
    return .init(bytesStored: Int64(data.count), isComplete: true)
  }

  func requests() -> [ResumableDownloadRequest] { received }
  func replaceContent(_ content: [String: Data]) { self.content = content }
}

private actor FakeSmokeTester: ModelPackSmokeTesting {
  private var versions: [String] = []
  private var failingVersions: Set<String> = []

  func validate(packAt directory: URL, manifest: ModelPackManifest) async throws {
    versions.append(manifest.version)
    if failingVersions.contains(manifest.version) { throw ModelPackError.smokeTestFailed }
  }

  func testedVersions() -> [String] { versions }
  func fail(version: String) { failingVersions.insert(version) }
  func allowAll() { failingVersions.removeAll() }
}

private actor InterruptOnceDownloader: ResumableArtifactDownloading {
  private let content: [String: Data]
  private var didInterrupt = false
  private var receivedOffsets: [Int64] = []

  init(content: [String: Data]) { self.content = content }

  func download(_ request: ResumableDownloadRequest) async throws -> ResumableDownloadResult {
    receivedOffsets.append(request.resumeOffset)
    guard let data = content[request.source.absoluteString] else {
      throw ModelPackError.downloadFailed
    }
    if !didInterrupt {
      didInterrupt = true
      try Data(data.prefix(2)).write(to: request.destination, options: [.atomic])
      throw ModelPackError.downloadFailed
    }
    if !FileManager.default.fileExists(atPath: request.destination.path) {
      FileManager.default.createFile(atPath: request.destination.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: request.destination)
    try handle.seekToEnd()
    try handle.write(contentsOf: data.dropFirst(Int(request.resumeOffset)))
    try handle.close()
    return .init(bytesStored: Int64(data.count), isComplete: true)
  }

  func offsets() -> [Int64] { receivedOffsets }
}
