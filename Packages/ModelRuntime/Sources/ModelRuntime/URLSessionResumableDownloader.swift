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
    guard request.expectedSize > 0, request.resumeOffset >= 0,
      request.resumeOffset <= request.expectedSize else { throw ModelPackError.downloadFailed }
    var urlRequest = URLRequest(url: request.source)
    urlRequest.httpMethod = "GET"
    if request.resumeOffset > 0 {
      urlRequest.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
    }

    let (bytes, response) = try await session.bytes(for: urlRequest)
    defer { bytes.task.cancel() }
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

    let initialSize = shouldAppend ? request.resumeOffset : 0
    guard response.expectedContentLength < 0
      || response.expectedContentLength <= request.expectedSize - initialSize else {
      throw ModelPackError.downloadExceededExpectedSize
    }
    try FileManager.default.createDirectory(
      at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: request.destination.path) {
      FileManager.default.createFile(atPath: request.destination.path, contents: nil)
    }
    let output = try FileHandle(forWritingTo: request.destination)
    defer { try? output.close() }
    if shouldAppend {
      guard try storedSize(at: request.destination) == initialSize else {
        throw ModelPackError.downloadFailed
      }
      try output.seekToEnd()
    } else {
      try output.truncate(atOffset: 0)
    }
    var size = initialSize
    var chunk = Data()
    chunk.reserveCapacity(65_536)
    for try await byte in bytes {
      guard size < request.expectedSize else { throw ModelPackError.downloadExceededExpectedSize }
      size += 1
      chunk.append(byte)
      if chunk.count == 65_536 {
        try Task.checkCancellation()
        try output.write(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
      }
    }
    try Task.checkCancellation()
    if !chunk.isEmpty { try output.write(contentsOf: chunk) }
    return .init(bytesStored: size, isComplete: size == request.expectedSize)
  }

  private func storedSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else { throw ModelPackError.fileSystemFailure }
    return size.int64Value
  }
}
