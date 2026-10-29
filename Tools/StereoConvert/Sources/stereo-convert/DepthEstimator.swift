//
//  DepthEstimator.swift
//  stereo-convert
//
//  Core ML の深度推定（Depth Anything V2）で、コマの深度を求める。
//  モデルの入力は決まった大きさの画像（BGRA）。出力は相対的な深度（近いほど大きい）の 1 チャンネルの画像
//

import Accelerate
import CoreML
import CoreVideo
import Foundation

final class DepthEstimator {
    let inputWidth: Int
    let inputHeight: Int
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    /// モデルに渡す、縮めたコマ（使い回す）
    private let input: CVPixelBuffer

    init(modelURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ConvertError.modelMissing(modelURL)
        }
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try await MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        let description = model.modelDescription
        guard let (name, feature) = description.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = feature.imageConstraint else {
            throw ConvertError.failed("モデルに画像の入力がありません")
        }
        let outputs = description.outputDescriptionsByName
        guard let output = outputs["depth"].map(\.name) ?? outputs.keys.first else {
            throw ConvertError.failed("モデルに出力がありません")
        }
        inputName = name
        outputName = output
        inputWidth = constraint.pixelsWide
        inputHeight = constraint.pixelsHigh
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, inputWidth, inputHeight, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else {
            throw ConvertError.failed("モデルに渡す画像を作れません")
        }
        input = buffer
    }

    /// frame（BGRA）の深度（近いほど大きい。大きさは inputWidth × inputHeight）
    func depth(of frame: CVPixelBuffer) throws -> [Float] {
        try scale(frame)
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
        let value = try model.prediction(from: features).featureValue(for: outputName)
        if let buffer = value?.imageBufferValue {
            return try Self.read(buffer)
        }
        if let array = value?.multiArrayValue {
            return (0..<array.count).map { array[$0].floatValue }
        }
        throw ConvertError.failed("モデルの出力を読めません")
    }

    /// コマを、モデルの入力の大きさに縮める（縦横比は合わせない。モデルはゆがんだ絵でも深度の並びを保つ）
    private func scale(_ frame: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(input, [])
        defer {
            CVPixelBufferUnlockBaseAddress(input, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(frame),
            height: vImagePixelCount(CVPixelBufferGetHeight(frame)),
            width: vImagePixelCount(CVPixelBufferGetWidth(frame)),
            rowBytes: CVPixelBufferGetBytesPerRow(frame)
        )
        var target = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(input),
            height: vImagePixelCount(inputHeight),
            width: vImagePixelCount(inputWidth),
            rowBytes: CVPixelBufferGetBytesPerRow(input)
        )
        let error = vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else {
            throw ConvertError.failed("コマを縮められません（vImage \(error)）")
        }
    }

    /// 1 チャンネルの画像（16 bit の浮動小数・32 bit の浮動小数）を読む
    private static func read(_ buffer: CVPixelBuffer) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(buffer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        var result = [Float](repeating: 0, count: width * height)
        let error = result.withUnsafeMutableBufferPointer { pointer in
            var target = vImage_Buffer(
                data: pointer.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * MemoryLayout<Float>.stride
            )
            return switch CVPixelBufferGetPixelFormatType(buffer) {
            case kCVPixelFormatType_OneComponent16Half:
                vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
            case kCVPixelFormatType_OneComponent32Float:
                vImageCopyBuffer(&source, &target, MemoryLayout<Float>.stride, vImage_Flags(kvImageNoFlags))
            default:
                kvImageInvalidImageFormat
            }
        }
        guard error == kvImageNoError else {
            throw ConvertError.failed("深度の画像を読めません（vImage \(error)）")
        }
        return result
    }
}
