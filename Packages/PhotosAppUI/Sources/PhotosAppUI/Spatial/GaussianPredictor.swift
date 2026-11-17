import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Turns one photo into a 3D scene of Gaussian splats with Apple's SHARP model
/// ("Sharp Monocular View Synthesis in Less Than a Second", apple/ml-sharp), run on the iPhone
/// through Core ML. This is the same kind of scene the system Photos app shows for its
/// spatial scenes: real 3D, with what's hidden behind the subject filled in by the model.
///
/// The model is converted by `Scripts/build-sharp-model.sh` (research licence: evaluation only).
/// Builds without it fall back to the depth-map renderer (`DepthEstimator`, `SpatialRenderer`).
actor GaussianPredictor {
    static let shared = GaussianPredictor()
    static let modelName = "SharpGaussians"
    /// The model's fixed input: the photo is squeezed to this square, and unsqueezed afterwards.
    static let inputSide = 1536
    /// SHARP's own default when a photo carries no focal length: 30 mm on 35 mm film.
    static let defaultFocal35mm: Float = 30

    nonisolated static var isAvailable: Bool { modelURL != nil }
    nonisolated static var modelURL: URL? { Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") }

    private var model: MLModel?
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// For diagnostics.
    private(set) var loadSeconds = 0.0
    private(set) var predictSeconds = 0.0
    private(set) var buildSeconds = 0.0

    /// Loads the model (about 1.2 GB of weights). The GPU runs it: the Neural Engine takes far
    /// longer to prepare a model this size each time it's loaded.
    func prepare(computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard model == nil else { return }
        guard let url = Self.modelURL else { throw SpatialError.modelMissing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let started = Date()
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw SpatialError.modelFailed(error.localizedDescription)
        }
        loadSeconds = Date().timeIntervalSince(started)
    }

    func unload() {
        model = nil
    }

    /// The scene for an upright photo. `focal35mm`: the lens's focal length on 35 mm film, if known.
    func cloud(for image: CGImage, focal35mm: Float? = nil) throws -> GaussianCloud {
        try prepare()
        guard let model else { throw SpatialError.modelMissing }
        let result = try Self.run(model: model, image: image, focal35mm: focal35mm, context: context)
        predictSeconds = result.predictSeconds
        buildSeconds = result.buildSeconds
        return result.cloud
    }

    /// Runs a loaded SHARP model on an upright photo (also used by the Mac test harness).
    static func run(model: MLModel, image: CGImage, focal35mm: Float? = nil, context: CIContext = CIContext())
        throws -> (cloud: GaussianCloud, predictSeconds: Double, buildSeconds: Double) {
        let side = inputSide
        let width = image.width, height = image.height
        // Focal length in pixels of the photo, as SHARP works it out.
        let diagonal = Double(width * width + height * height).squareRoot() / (36.0 * 36.0 + 24.0 * 24.0).squareRoot()
        let focal = (focal35mm ?? defaultFocal35mm) * Float(diagonal)

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { throw SpatialError.modelFailed("") }
        let source = CIImage(cgImage: image)
        let squeezed = source.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / source.extent.width, y: CGFloat(side) / source.extent.height))
        context.render(squeezed, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let started = Date()
        let output: MLFeatureProvider
        do {
            let factor = try MLMultiArray(shape: [1], dataType: .float32)
            factor[0] = NSNumber(value: focal / Float(width))
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: buffer),
                "disparity_factor": MLFeatureValue(multiArray: factor),
            ])
            output = try model.prediction(from: input)
        } catch {
            throw SpatialError.modelFailed(error.localizedDescription)
        }
        let predictSeconds = Date().timeIntervalSince(started)
        func array(_ name: String) throws -> MLMultiArray {
            guard let value = output.featureValue(for: name)?.multiArrayValue else { throw SpatialError.modelFailed("no \(name)") }
            return value
        }
        let built = Date()
        let cloud = try GaussianCloud(
            means: array("means"), scales: array("scales"), quaternions: array("quaternions"),
            colors: array("colors"), opacities: array("opacities"),
            imageWidth: width, imageHeight: height, focal: focal
        )
        return (cloud, predictSeconds, Date().timeIntervalSince(built))
    }
}
