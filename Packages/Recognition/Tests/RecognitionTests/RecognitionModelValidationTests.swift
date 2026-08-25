import Foundation
import XCTest
@testable import Recognition

final class RecognitionModelValidationTests: XCTestCase {
    func testProductionFluidAudioConfigurationIsTheApprovedStreamingArtifact() {
        XCTAssertEqual(
            FluidAudioRecognitionConfiguration.mvp,
            .init(leftFrames: 70, chunkFrames: 7, rightFrames: 1, encoderPrecision: "int8")
        )
        XCTAssertEqual(
            RecognitionModelLayout.unifiedEncoderBundleName,
            "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc"
        )
    }
    func testCompleteUnifiedModelDirectoryPassesSmokeValidation() throws {
        let directory = try TemporaryModelDirectory.complete()
        defer { directory.remove() }

        let result = try RecognitionModelValidator.validate(
            .init(unifiedModelDirectory: directory.url)
        )

        XCTAssertEqual(result, .init(personalVocabularyAvailable: false))
    }

    func testMissingContextSpecificInt8EncoderIsRejected() throws {
        let directory = try TemporaryModelDirectory.complete()
        defer { directory.remove() }
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent(
            RecognitionModelLayout.unifiedEncoderBundleName
        ))

        XCTAssertThrowsError(try RecognitionModelValidator.validate(
            .init(unifiedModelDirectory: directory.url)
        )) { error in
            XCTAssertEqual(
                error as? RecognitionModelValidationError,
                .missingAsset(RecognitionModelLayout.unifiedEncoderBundleName)
            )
        }
    }

    func testConfiguredCTCAssetsAreValidatedAndReportVocabularyCapability() throws {
        let unified = try TemporaryModelDirectory.complete()
        let ctc = try TemporaryModelDirectory.completeCTC()
        defer {
            unified.remove()
            ctc.remove()
        }

        let result = try RecognitionModelValidator.validate(.init(
            unifiedModelDirectory: unified.url,
            ctcModelDirectory: ctc.url
        ))

        XCTAssertEqual(result, .init(personalVocabularyAvailable: true))
    }

    func testIncompleteOptionalCTCAssetsAreRejectedInsteadOfSilentlyDisablingVocabulary() throws {
        let unified = try TemporaryModelDirectory.complete()
        let ctc = try TemporaryModelDirectory.completeCTC()
        defer {
            unified.remove()
            ctc.remove()
        }
        try FileManager.default.removeItem(at: ctc.url.appendingPathComponent("tokenizer.json"))

        XCTAssertThrowsError(try RecognitionModelValidator.validate(.init(
            unifiedModelDirectory: unified.url,
            ctcModelDirectory: ctc.url
        ))) { error in
            XCTAssertEqual(
                error as? RecognitionModelValidationError,
                .missingAsset("tokenizer.json")
            )
        }
    }
}

private struct TemporaryModelDirectory {
    let url: URL

    static func complete() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in RecognitionModelLayout.unifiedModelBundleNames {
            let bundle = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([0x01]).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        try Data("{\"0\":\"<blank>\"}".utf8).write(
            to: root.appendingPathComponent(RecognitionModelLayout.unifiedVocabularyName)
        )
        return .init(url: root)
    }

    static func completeCTC() throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in RecognitionModelLayout.ctcModelBundleNames {
            let bundle = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data([0x01]).write(to: bundle.appendingPathComponent("coremldata.bin"))
        }
        for name in RecognitionModelLayout.ctcJSONAssetNames {
            try Data("{\"0\":\"token\"}".utf8).write(to: root.appendingPathComponent(name))
        }
        return .init(url: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
