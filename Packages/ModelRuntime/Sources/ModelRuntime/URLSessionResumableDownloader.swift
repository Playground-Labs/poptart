import Foundation

extension ResumableArtifactDownloading where Self == URLSessionResumableDownloader {
  /// The production downloader. Named here so the App composition root can
  /// inject it without spelling a network type, which the privacy scan forbids
  /// outside this file.
  public static var system: URLSessionResumableDownloader { .init() }
}

public struct URLSessionResumableDownloader: ResumableArtifactDownloading, Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func download(_ request: ResumableDownloadRequest) async throws -> ResumableDownloadResult
  {
    var urlRequest = URLRequest(url: request.source)
    urlRequest.httpMethod = "GET"
    if request.resumeOffset > 0 {
      urlRequest.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
    }

    let (temporaryURL, response) = try await session.download(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw ModelPackError.downloadFailed }
    let shouldAppend: Bool
    switch (request.resumeOffset, http.statusCode) {
    case (0, 200), (0, 206):
      shouldAppend = false
    case (let offset, 206) where offset > 0:
      guard http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true
      else {
        throw ModelPackError.downloadFailed
      }
      shouldAppend = true
    case (let offset, 200) where offset > 0:
      // A server may ignore Range. Its full response safely replaces the partial artifact.
      shouldAppend = false
    default:
      throw ModelPackError.downloadFailed
    }

    try FileManager.default.createDirectory(
      at: request.destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if shouldAppend {
      try appendFile(at: temporaryURL, to: request.destination)
    } else {
      if FileManager.default.fileExists(atPath: request.destination.path) {
        try FileManager.default.removeItem(at: request.destination)
      }
      try FileManager.default.moveItem(at: temporaryURL, to: request.destination)
    }
    let size = try storedSize(at: request.destination)
    guard size <= request.expectedSize else {
      throw ModelPackError.downloadExceededExpectedSize
    }
    return .init(bytesStored: size, isComplete: size == request.expectedSize)
  }

  private func appendFile(at source: URL, to destination: URL) throws {
    if !FileManager.default.fileExists(atPath: destination.path) {
      FileManager.default.createFile(atPath: destination.path, contents: nil)
    }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
      try? FileManager.default.removeItem(at: source)
    }
    try output.seekToEnd()
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
      try output.write(contentsOf: chunk)
    }
  }

  private func storedSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else { throw ModelPackError.fileSystemFailure }
    return size.int64Value
  }
}
