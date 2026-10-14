// Vendored from FluidAudio (https://github.com/FluidInference/FluidAudio),
// commit 793a2c5, Sources/FluidAudio/Diarizer/Nemotron3/Nemotron3Models.swift.
// Copyright Fluid Inference. Licensed under the Apache License, Version 2.0;
// see THIRD-PARTY-LICENSES.txt. Local changes are marked "airlock:".

@preconcurrency import CoreML
import Accelerate
import Foundation

/// Container for the Nemotron 3 Diarization CoreML model and the learned silence embedding.
///
/// Download with `loadFromHuggingFace`, or point `load` at a local directory holding the
/// variant's `.mlmodelc` (or `.mlpackage`) and `learnable_sil_emb.bin` (512 float32,
/// little-endian).
public struct Nemotron3Models {
    public let model: MLModel
    /// Learned silence embedding, [512]. Used for disabled frames during cache compression.
    public let silenceEmbedding: [Float]
    /// FeatureStacking projection, [1024, 512] row-major (W^T). Split-graph mode only.
    public let preEncodeProjection: [Float]?
    public let compilationDuration: TimeInterval

    private let packedArray: MLMultiArray?
    private let attnBiasArray: MLMultiArray?
    private let outputMaskArray: MLMultiArray?

    /// Preallocated output backings (contiguous, in the model's declared output type).
    /// Reusing them removes the per-call output IOSurface allocation — the root cause of
    /// pool exhaustion on long ANE runs — and shaves per-call marshaling overhead.
    private let predsBacking: MLMultiArray
    private let hiresBacking: MLMultiArray
    private let embsBacking: MLMultiArray?
    private let predictionOptions: MLPredictionOptions

    public init(
        config: Nemotron3Config,
        model: MLModel,
        silenceEmbedding: [Float],
        preEncodeProjection: [Float]? = nil,
        compilationDuration: TimeInterval = 0
    ) throws {
        self.model = model
        self.silenceEmbedding = silenceEmbedding
        self.preEncodeProjection = preEncodeProjection
        self.compilationDuration = compilationDuration

        // airlock: only the split-graph presets are vendored, so the monolithic
        // path's input arrays (and FluidAudio's ANEMemoryOptimizer) are left out.
        guard config.splitGraph else {
            throw Nemotron3Error.modelLoadFailed("only split-graph presets are supported")
        }
        if config.splitGraph {
            let t = config.packedFrames
            // packed's innermost dim (512) is tile-aligned, so the aligned array is
            // contiguous. The mask inputs are NOT: the aligned helper pads innermost
            // dims to tile boundaries (output_mask [1,T,1] would get row stride 16,
            // scrambling linear writes) — use plain contiguous MLMultiArrays for them.
            // airlock: 64-byte-aligned contiguous float32, in place of ANEMemoryOptimizer.
            self.packedArray = try Self.alignedFloats(shape: [1, t, config.preEncoderDims])
            self.attnBiasArray = try MLMultiArray(
                shape: [1, 1, 1, NSNumber(value: t)], dataType: .float32)
            self.outputMaskArray = try MLMultiArray(
                shape: [1, NSNumber(value: t), 1], dataType: .float32)
        } else {
            self.packedArray = nil
            self.attnBiasArray = nil
            self.outputMaskArray = nil
        }

        // Typed from the model's output description: some runtimes reject a backing whose
        // type differs from the declared one (#951). Plain MLMultiArrays are contiguous,
        // which also simplifies readback.
        let t = config.packedFrames
        let up = config.upsampleFactor
        let s = config.numSpeakers
        self.predsBacking = try Self.outputBacking(
            model, "speaker_preds", shape: [1, t, s])
        self.hiresBacking = try Self.outputBacking(
            model, "speaker_preds_10ms", shape: [1, t * up, s])
        if config.splitGraph {
            self.embsBacking = nil
        } else {
            self.embsBacking = try Self.outputBacking(
                model, "chunk_pre_encode_embs", shape: [1, config.chunkEncFrames, config.preEncoderDims])
        }
        let options = MLPredictionOptions()
        var backings: [String: MLMultiArray] = [
            "speaker_preds": predsBacking,
            "speaker_preds_10ms": hiresBacking,
        ]
        if let embsBacking { backings["chunk_pre_encode_embs"] = embsBacking }
        options.outputBackings = backings
        self.predictionOptions = options
    }

    /// Contiguous backing for `name` in its declared output type.
    static func outputBacking(_ model: MLModel, _ name: String, shape: [Int]) throws -> MLMultiArray {
        try outputBacking(
            declaredType: model.modelDescription.outputDescriptionsByName[name]?.multiArrayConstraint?.dataType,
            shape: shape)
    }

    /// Contiguous backing of `declaredType` (fp16 if the model declares none).
    static func outputBacking(declaredType: MLMultiArrayDataType?, shape: [Int]) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: declaredType ?? .float16)
    }

    /// Load from a local models directory holding `config.modelFileName` (or its
    /// `.mlpackage`) plus `learnable_sil_emb.bin` (and `pre_encode_proj_t.bin` for
    /// split-graph presets).
    public static func load(
        config: Nemotron3Config,
        directory: URL,
        computeUnits: MLComputeUnits = .all
    ) async throws -> Nemotron3Models {
        try await load(
            config: config,
            modelURL: directory.appendingPathComponent(config.modelFileName),
            assetsDirectory: directory,
            computeUnits: computeUnits)
    }

    // airlock: FluidAudio's Hugging Face download and cache handling are left
    // out. Airlock fetches the files itself and loads them from a local folder.

    private static func load(
        config: Nemotron3Config,
        modelURL requestedModelURL: URL,
        assetsDirectory directory: URL,
        computeUnits: MLComputeUnits
    ) async throws -> Nemotron3Models {
        let start = Date()

        var modelURL = requestedModelURL
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            // Fall back to the uncompiled mlpackage next to the expected mlmodelc.
            let packageURL = modelURL.deletingPathExtension().appendingPathExtension("mlpackage")
            guard FileManager.default.fileExists(atPath: packageURL.path) else {
                throw Nemotron3Error.modelLoadFailed(
                    "Neither \(config.modelFileName) nor its .mlpackage found at \(modelURL.deletingLastPathComponent().path)"
                )
            }
            modelURL = try await MLModel.compileModel(at: packageURL)
        }

        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = computeUnits
        let model = try MLModel(contentsOf: modelURL, configuration: mlConfig)

        let silURL = directory.appendingPathComponent("learnable_sil_emb.bin")
        guard let silData = try? Data(contentsOf: silURL) else {
            throw Nemotron3Error.modelLoadFailed("Missing learnable_sil_emb.bin in \(directory.path)")
        }
        let silCount = silData.count / MemoryLayout<Float>.size
        guard silCount == config.preEncoderDims else {
            throw Nemotron3Error.modelLoadFailed(
                "learnable_sil_emb.bin has \(silCount) floats, expected \(config.preEncoderDims)")
        }
        let silenceEmbedding = silData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        var projection: [Float]? = nil
        if config.splitGraph {
            let projURL = directory.appendingPathComponent("pre_encode_proj_t.bin")
            guard let projData = try? Data(contentsOf: projURL),
                projData.count == 1024 * 512 * MemoryLayout<Float>.size
            else {
                throw Nemotron3Error.modelLoadFailed(
                    "Split-graph mode requires pre_encode_proj_t.bin ([1024,512] fp32) in \(directory.path)")
            }
            projection = projData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        let duration = Date().timeIntervalSince(start)
        return try Nemotron3Models(
            config: config, model: model, silenceEmbedding: silenceEmbedding,
            preEncodeProjection: projection, compilationDuration: duration)
    }

    // MARK: - Split-graph inference

    /// Run one streaming step through the split graph: host does feature stacking, the
    /// 1024->512 projection, state packing, and mask construction; the model is the pure
    /// transformer+head. Returns the same `Output` contract (chunk embeddings host-computed).
    public func runSplit(
        chunk: [Float],
        chunkLength: Int,
        state: Nemotron3StreamingState,
        config: Nemotron3Config
    ) throws -> Output {
        guard let packedArray, let attnBiasArray, let outputMaskArray,
            let projection = preEncodeProjection
        else {
            throw Nemotron3Error.invalidState("runSplit called on a non-split configuration")
        }
        let d = config.preEncoderDims
        let sub = config.subsamplingFactor
        let t = config.packedFrames

        var tStage = Date()
        // Feature stacking is a pure reshape of the zero-padded fixed-size mel buffer:
        // [mel, 128] row-major == [mel/8, 1024]. Project with one sgemm.
        let encCapacity = config.chunkMelFrames / sub
        var chunkEmbs = [Float](repeating: 0, count: encCapacity * d)
        chunk.withUnsafeBufferPointer { src in
            chunkEmbs.withUnsafeMutableBufferPointer { dst in
                projection.withUnsafeBufferPointer { proj in
                    cblas_sgemm(
                        CblasRowMajor, CblasNoTrans, CblasNoTrans,
                        Int32(encCapacity), Int32(d), Int32(1024),
                        1.0, src.baseAddress, Int32(1024),
                        proj.baseAddress, Int32(d),
                        0.0, dst.baseAddress, Int32(d))
                }
            }
        }
        let encLen = (chunkLength + sub - 1) / sub

        // Pack [spkcache | fifo | chunk] valid frames, zero-pad, build masks.
        let packedPtr = packedArray.dataPointer.bindMemory(to: Float.self, capacity: t * d)
        var pos = 0
        for (buffer, n) in [
            (state.spkcache, state.spkcacheLength), (state.fifo, state.fifoLength),
            (chunkEmbs, encLen),
        ] {
            buffer.withUnsafeBufferPointer { src in
                packedPtr.advanced(by: pos * d).update(from: src.baseAddress!, count: n * d)
            }
            pos += n
        }
        if pos < t {
            packedPtr.advanced(by: pos * d).update(repeating: 0, count: (t - pos) * d)
        }
        let biasPtr = attnBiasArray.dataPointer.bindMemory(to: Float.self, capacity: t)
        let maskPtr = outputMaskArray.dataPointer.bindMemory(to: Float.self, capacity: t)
        biasPtr.update(repeating: 0, count: pos)
        biasPtr.advanced(by: pos).update(repeating: -30000.0, count: t - pos)
        maskPtr.update(repeating: 1, count: pos)
        maskPtr.advanced(by: pos).update(repeating: 0, count: t - pos)

        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "packed": MLFeatureValue(multiArray: packedArray),
            "attn_bias": MLFeatureValue(multiArray: attnBiasArray),
            "output_mask": MLFeatureValue(multiArray: outputMaskArray),
        ])
        let inputPrepSeconds = Date().timeIntervalSince(tStage)

        tStage = Date()
        let output = try predict(inputs)
        let predictSeconds = Date().timeIntervalSince(tStage)
        tStage = Date()

        let predsArray = output.featureValue(for: "speaker_preds")?.multiArrayValue ?? predsBacking
        let hiresArray = output.featureValue(for: "speaker_preds_10ms")?.multiArrayValue ?? hiresBacking
        return Output(
            predictions: Self.floats(from: predsArray),
            highResPredictions: Self.floats(from: hiresArray),
            chunkEmbeddings: chunkEmbs,
            chunkLength: encLen,
            inputPrepSeconds: inputPrepSeconds,
            predictSeconds: predictSeconds,
            readbackSeconds: Date().timeIntervalSince(tStage)
        )
    }

    /// Predict with the preallocated output backings, dropping them for good if the
    /// runtime still rejects them (e.g. after a failed ANE compile on M3 Max, #951).
    private func predict(_ inputs: MLFeatureProvider) throws -> MLFeatureProvider {
        do {
            return try model.prediction(from: inputs, options: predictionOptions)
        } catch {
            guard !predictionOptions.outputBackings.isEmpty else { throw error }
            // airlock: FluidAudio logs a warning here.
            predictionOptions.outputBackings = [:]
            return try model.prediction(from: inputs, options: predictionOptions)
        }
    }

    // MARK: - Inference

    public struct Output {
        /// 80 ms packed predictions [spkcacheLen + fifoLen + chunkEncFrames, 8] flattened.
        public let predictions: [Float]
        /// 10 ms packed predictions [(spkcacheLen + fifoLen + chunkEncFrames) * 8, 8] flattened.
        public let highResPredictions: [Float]
        /// Chunk pre-encode embeddings [chunkEncFrames, 512] flattened.
        public let chunkEmbeddings: [Float]
        /// Valid encoder frames in `chunkEmbeddings`.
        public let chunkLength: Int
        /// Per-call wall time split: input tensor copies, CoreML predict, output readback.
        public let inputPrepSeconds: Double
        public let predictSeconds: Double
        public let readbackSeconds: Double
    }

    // airlock: the monolithic graph's `run` is left out (split-graph only).

    /// airlock: a zeroed, 64-byte-aligned, contiguous float32 array.
    static func alignedFloats(shape: [Int]) throws -> MLMultiArray {
        let count = shape.reduce(1, *)
        let bytes = max(64, (count * MemoryLayout<Float>.size + 63) / 64 * 64)
        var pointer: UnsafeMutableRawPointer?
        guard posix_memalign(&pointer, 64, bytes) == 0, let pointer else {
            throw Nemotron3Error.modelLoadFailed("could not allocate \(bytes) bytes")
        }
        memset(pointer, 0, bytes)
        var strides: [Int] = []
        var step = 1
        for size in shape.reversed() {
            strides.insert(step, at: 0)
            step *= size
        }
        return try MLMultiArray(
            dataPointer: pointer, shape: shape.map { NSNumber(value: $0) }, dataType: .float32,
            strides: strides.map { NSNumber(value: $0) }, deallocator: { free($0) })
    }

    /// Direct-pointer MLMultiArray -> [Float] copy, honoring strides (reading a strided
    /// array through the contiguous fast path scrambles element order — FluidAudio #612).
    ///
    /// The model's outputs are fp16 with padded rows (e.g. shape [1, T, 8] with row
    /// stride 16), so this does one bulk fp16->fp32 conversion over the padded extent
    /// followed by a single `vDSP_mmov` 2D compaction, instead of per-element NSNumber
    /// reads or `shapedArrayValue` (~1.6 ms/chunk at fast32).
    static func floats(from array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let count = shape.reduce(1, *)

        // Collapse leading singleton dims to a rows x cols view with unit column stride.
        // All model outputs are [1, R, C]; also handle fully contiguous arrays as one row.
        var rows = 1
        var cols = count
        var rowStride = count
        if let last = strides.last, last == 1 {
            if shape.count >= 2, shape.dropLast(2).allSatisfy({ $0 == 1 }) {
                rows = shape[shape.count - 2]
                cols = shape[shape.count - 1]
                rowStride = strides[strides.count - 2]
            } else if strides == (0..<shape.count).map({ d in shape[(d + 1)...].reduce(1, *) }) {
                rows = 1
                cols = count
                rowStride = count
            } else {
                return floatsViaSubscript(array, count: count)
            }
        } else {
            return floatsViaSubscript(array, count: count)
        }

        let paddedCount = (rows - 1) * rowStride + cols
        var result = [Float](repeating: 0, count: count)

        switch array.dataType {
        case .float32:
            let src = array.dataPointer.bindMemory(to: Float.self, capacity: paddedCount)
            result.withUnsafeMutableBufferPointer { dst in
                vDSP_mmov(
                    src, dst.baseAddress!, vDSP_Length(cols), vDSP_Length(rows),
                    vDSP_Length(rowStride), vDSP_Length(cols))
            }
        #if arch(arm64)
        case .float16:
            let src = array.dataPointer.bindMemory(to: Float16.self, capacity: paddedCount)
            var scratch = [Float](repeating: 0, count: paddedCount)
            let srcBuffer = UnsafeBufferPointer(start: src, count: paddedCount)
            scratch.withUnsafeMutableBufferPointer { dst in
                vDSP.convertElements(of: srcBuffer, to: &dst)
            }
            scratch.withUnsafeBufferPointer { s in
                result.withUnsafeMutableBufferPointer { dst in
                    vDSP_mmov(
                        s.baseAddress!, dst.baseAddress!, vDSP_Length(cols), vDSP_Length(rows),
                        vDSP_Length(rowStride), vDSP_Length(cols))
                }
            }
        #endif
        default:
            return floatsViaSubscript(array, count: count)
        }
        return result
    }

    private static func floatsViaSubscript(_ array: MLMultiArray, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            result[i] = array[i].floatValue
        }
        return result
    }
}
