// ============================================================================
// CAM++.swift — Independent CAM++ speaker embedding extractor
// CoreML-based, no FluidAudio internal dependency
// ============================================================================

import Foundation
import CoreML
import AVFAudio
import OhrCore

// MARK: - CAM++ Models

/// Manages download and loading of CAM++ CoreML models (preprocessor + embedding).
enum CAMPlusModels {
    static let embeddingDim = 192
    private static let repo = "FluidInference/campplus-coreml"

    /// Directory where models are cached.
    static var modelsDirectory: URL {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
                .appendingPathComponent("ohr-campplus", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("ohr-campplus", isDirectory: true)
    }

    /// Check if models are already cached on disk.
    static func modelsExist() -> Bool {
        let dir = modelsDirectory
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("CamPlusPreprocessor.mlmodelc").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("CamPlusPlus.mlmodelc").path)
    }

    /// Download CAM++ models from HuggingFace (or mirror via REGISTRY_URL).
    static func download() async throws {
        if modelsExist() { return }

        let dir = modelsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let baseURL: String = {
            if let mirror = ProcessInfo.processInfo.environment["REGISTRY_URL"] {
                return mirror
            }
            return "https://huggingface.co"
        }()

        let files = [
            "CamPlusPreprocessor.mlmodelc/model.mil",
            "CamPlusPreprocessor.mlmodelc/coremldata.bin",
            "CamPlusPreprocessor.mlmodelc/analytics/coremldata.bin",
            "CamPlusPreprocessor.mlmodelc/weights/weight.bin",
            "CamPlusPlus.mlmodelc/model.mil",
            "CamPlusPlus.mlmodelc/coremldata.bin",
            "CamPlusPlus.mlmodelc/analytics/coremldata.bin",
            "CamPlusPlus.mlmodelc/weights/weight.bin",
        ]

        for file in files {
            let url = URL(string: "\(baseURL)/\(repo)/resolve/main/\(file)")!
            let dest = dir.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: dest.path) { continue }

            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OhrError.transcriptionFailed("Download failed for \(file)")
            }
            try data.write(to: dest)
        }
    }

    /// Load both preprocessor and embedding models.
    static func load() throws -> (preprocessor: MLModel, model: MLModel) {
        let dir = modelsDirectory

        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly

        let gpuConfig = MLModelConfiguration()
        gpuConfig.computeUnits = .cpuAndGPU

        let preprocessor = try loadModel(at: dir.appendingPathComponent("CamPlusPreprocessor.mlmodelc"), config: cpuConfig)
        let model = try loadModel(at: dir.appendingPathComponent("CamPlusPlus.mlmodelc"), config: gpuConfig)

        return (preprocessor, model)
    }

    private static func loadModel(at url: URL, config: MLModelConfiguration) throws -> MLModel {
        // Compile if .mlpackage, otherwise load compiled .mlmodelc
        var modelURL = url
        if !FileManager.default.fileExists(atPath: url.path) {
            let pkgURL = url.deletingPathExtension().appendingPathExtension("mlpackage")
            guard FileManager.default.fileExists(atPath: pkgURL.path) else {
                throw OhrError.transcriptionFailed("Model not found at \(url.path) or \(pkgURL.path)")
            }
            modelURL = try MLModel.compileModel(at: pkgURL)
        }
        return try MLModel(contentsOf: modelURL, configuration: config)
    }
}

// MARK: - CAM++ Embedder

/// CAM++ speaker-embedding extractor: waveform → 192-d L2-normalized embedding.
actor CAMPlusEmbedder {
    private let preprocessor: MLModel
    private let model: MLModel

    private static let waveformScale: Float = 32_768.0

    init(preprocessor: MLModel, model: MLModel) {
        self.preprocessor = preprocessor
        self.model = model
    }

    /// Load (and download if needed) CAM++ models, then create an embedder.
    static func load() async throws -> CAMPlusEmbedder {
        if !CAMPlusModels.modelsExist() {
            try await CAMPlusModels.download()
        }
        let models = try CAMPlusModels.load()
        return CAMPlusEmbedder(preprocessor: models.preprocessor, model: models.model)
    }

    /// Embed a 16 kHz mono audio file → 192-d L2-normalized embedding.
    func embed(audioURL: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: UInt32(audioFile.length)),
              let _ = try? audioFile.read(into: buffer) else {
            throw OhrError.transcriptionFailed("Failed to read audio file")
        }
        guard let channelData = buffer.floatChannelData else {
            throw OhrError.transcriptionFailed("No float channel data")
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return try embed(samples: samples)
    }

    /// Embed 16 kHz mono samples ([-1, 1]) → 192-d L2-normalized embedding.
    func embed(samples: [Float]) throws -> [Float] {
        let n = samples.count
        let wav = try MLMultiArray(shape: [1, n as NSNumber], dataType: .float32)
        let p = wav.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<n { p[i] = samples[i] * Self.waveformScale }

        // Step 1: Preprocessor (waveform → 80-d fbank)
        let feats = try preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "waveform": MLFeatureValue(multiArray: wav)
            ]))
        guard let fbank = feats.featureValue(for: "features")?.multiArrayValue else {
            throw OhrError.transcriptionFailed("CAM++ preprocessor produced no `features`")
        }

        // Step 2: CAM++ (fbank → 192-d embedding)
        let out = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "feats": MLFeatureValue(multiArray: fbank)
            ]))
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
            throw OhrError.transcriptionFailed("CAM++ model produced no `embedding`")
        }

        var v = [Float](repeating: 0, count: emb.count)
        if emb.dataType == .float32 {
            let ep = emb.dataPointer.assumingMemoryBound(to: Float32.self)
            for i in 0..<emb.count { v[i] = ep[i] }
        } else {
            for i in 0..<emb.count { v[i] = emb[i].floatValue }
        }

        let norm = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return v.map { $0 / norm }
    }

    /// Cosine similarity of two L2-normalized embeddings.
    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
