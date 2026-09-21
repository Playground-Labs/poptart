import Foundation
import Testing
@testable import ModelRuntime

@Suite("Bounded model downloads")
struct DownloaderTests {
  @Test("Oversized responses never write beyond the declared bound", arguments: ["declared", "streamed"])
  func rejectsOversizedResponses(_ path: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("partial")
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    await #expect(throws: ModelPackError.downloadExceededExpectedSize) {
      try await URLSessionResumableDownloader(session: session).download(.init(
        source: URL(string: "https://download.invalid/\(path)")!, destination: destination,
        resumeOffset: 0, expectedSize: 65_536))
    }
    let stored = (try? Data(contentsOf: destination)) ?? Data()
    #expect(stored.count <= 65_536)
  }

  @Test("Range responses append and ignored Range responses replace partial data", arguments: ["resume", "restart"])
  func resumesOrRestarts(_ path: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("partial")
    try Data([1, 2]).write(to: destination)
    let session = makeSession()
    defer { session.invalidateAndCancel() }
    let result = try await URLSessionResumableDownloader(session: session).download(.init(
      source: URL(string: "https://download.invalid/\(path)")!, destination: destination,
      resumeOffset: 2, expectedSize: 4))
    #expect(result == .init(bytesStored: 4, isComplete: true))
    #expect(try Data(contentsOf: destination) == Data([1, 2, 3, 4]))
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class DownloadProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "download.invalid" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let path = request.url!.lastPathComponent
    let resumed = path == "resume" && request.value(forHTTPHeaderField: "Range") == "bytes=2-"
    let data = path == "restart" ? Data([1, 2, 3, 4])
      : resumed ? Data([3, 4]) : Data(repeating: 1, count: 65_537)
    let headers = resumed ? ["Content-Range": "bytes 2-3/4"]
      : path == "declared" ? ["Content-Length": "65537"] : [:]
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
      statusCode: resumed ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
}
