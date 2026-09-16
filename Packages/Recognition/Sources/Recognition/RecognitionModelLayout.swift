import FluidAudio
import Foundation

public struct RecognitionModelLayout: Equatable, Sendable {
    /// Derived from the production configuration so the bundle validation requires is always the
    /// bundle the streaming manager loads: the encoder bakes its `[left, chunk, right]` attention
    /// window and its weight precision into the file name.
    public static let unifiedEncoderBundleName = ModelNames.ParakeetUnified.streamingEncoderFile(
        precision: FluidAudioRecognitionConfiguration.mvp.encoderPrecision,
        contextSuffix: FluidAudioRecognitionConfiguration.mvp.unifiedConfig.contextSuffix
    )
    public static let unifiedDecoderBundleName = "parakeet_unified_decoder.mlmodelc"
    public static let unifiedJointBundleName =
        "parakeet_unified_joint_decision_single_step.mlmodelc"
    public static let unifiedVocabularyName = "vocab.json"

    public static let unifiedModelBundleNames = [
        unifiedEncoderBundleName,
        unifiedDecoderBundleName,
        unifiedJointBundleName,
    ]
    public static let ctcModelBundleNames = [
        "MelSpectrogram.mlmodelc",
        "AudioEncoder.mlmodelc",
    ]
    public static let ctcJSONAssetNames = ["vocab.json", "tokenizer.json"]
    public static let vadModelBundleName = ModelNames.VAD.sileroVadFile

    public let unifiedModelDirectory: URL
    public let ctcModelDirectory: URL?
    /// Deliberately absent from `RecognitionModelValidator`: a validation failure refuses to start
    /// recognition at all, and noise rejection must never be able to do that. A missing or broken
    /// voice activity model leaves the speech gate as a pass-through instead.
    public let vadModelDirectory: URL?

    public init(
        unifiedModelDirectory: URL,
        ctcModelDirectory: URL? = nil,
        vadModelDirectory: URL? = nil
    ) {
        self.unifiedModelDirectory = unifiedModelDirectory
        self.ctcModelDirectory = ctcModelDirectory
        self.vadModelDirectory = vadModelDirectory
    }
}

public struct FluidAudioRecognitionConfiguration: Equatable, Sendable {
    public static let mvp = Self(
        leftFrames: 70,
        chunkFrames: 7,
        rightFrames: 1,
        encoderPrecision: .int8
    )

    public let leftFrames: Int
    public let chunkFrames: Int
    public let rightFrames: Int
    public let encoderPrecision: UnifiedEncoderPrecision

    var unifiedConfig: UnifiedConfig {
        UnifiedConfig(leftFrames: leftFrames, chunkFrames: chunkFrames, rightFrames: rightFrames)
    }
}

public struct RecognitionModelValidation: Equatable, Sendable {
    public let personalVocabularyAvailable: Bool

    public init(personalVocabularyAvailable: Bool) {
        self.personalVocabularyAvailable = personalVocabularyAvailable
    }
}

public enum RecognitionModelValidationError: Error, Equatable, Sendable {
    case missingAsset(String)
    case emptyModelBundle(String)
    case invalidVocabulary(String)
}

public enum RecognitionModelValidator {
    public static func validate(
        _ layout: RecognitionModelLayout,
        fileManager: FileManager = .default
    ) throws -> RecognitionModelValidation {
        for name in RecognitionModelLayout.unifiedModelBundleNames {
            try validateModelBundle(
                layout.unifiedModelDirectory.appendingPathComponent(name, isDirectory: true),
                name: name,
                fileManager: fileManager
            )
        }
        try validateJSON(
            layout.unifiedModelDirectory.appendingPathComponent(
                RecognitionModelLayout.unifiedVocabularyName
            ),
            name: RecognitionModelLayout.unifiedVocabularyName,
            fileManager: fileManager
        )
        if let ctcDirectory = layout.ctcModelDirectory {
            for name in RecognitionModelLayout.ctcModelBundleNames {
                try validateModelBundle(
                    ctcDirectory.appendingPathComponent(name, isDirectory: true),
                    name: name,
                    fileManager: fileManager
                )
            }
            for name in RecognitionModelLayout.ctcJSONAssetNames {
                try validateJSON(
                    ctcDirectory.appendingPathComponent(name),
                    name: name,
                    fileManager: fileManager
                )
            }
        }
        return .init(personalVocabularyAvailable: layout.ctcModelDirectory != nil)
    }

    private static func validateModelBundle(
        _ url: URL,
        name: String,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RecognitionModelValidationError.missingAsset(name)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw RecognitionModelValidationError.emptyModelBundle(name)
        }
        while let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                return
            }
        }
        throw RecognitionModelValidationError.emptyModelBundle(name)
    }

    private static func validateJSON(
        _ url: URL,
        name: String,
        fileManager: FileManager
    ) throws {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw RecognitionModelValidationError.missingAsset(name)
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let object = try JSONSerialization.jsonObject(with: data)
            let hasContent: Bool
            if let array = object as? [Any] {
                hasContent = !array.isEmpty
            } else if let dictionary = object as? [String: Any] {
                hasContent = !dictionary.isEmpty
            } else {
                hasContent = false
            }
            guard !data.isEmpty, hasContent else {
                throw RecognitionModelValidationError.invalidVocabulary(name)
            }
        } catch let error as RecognitionModelValidationError {
            throw error
        } catch {
            throw RecognitionModelValidationError.invalidVocabulary(name)
        }
    }
}
