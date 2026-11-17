import CoreML
import Foundation
import simd

/// One photo as a 3D scene: a million or so small, soft, coloured blobs (Gaussian splats) in
/// metres, seen from a camera at the origin looking along +z (x right, y down), as SHARP makes it.
/// Kept in the layout the renderer reads, sorted farthest first so they can be blended in order.
struct GaussianCloud: Sendable {
    /// What the GPU reads for each splat (48 bytes; mirrored in `SplatRenderer`'s shader).
    struct Splat {
        var position: (Float, Float, Float)
        /// The 3D covariance (its shape and size), upper triangle: xx, xy, xz, yy, yz, zz.
        var covariance: (Float, Float, Float, Float, Float, Float)
        var padding: Float = 0
        /// Linear RGB and opacity.
        var color: (Float16, Float16, Float16, Float16)
    }

    let count: Int
    /// `count` splats, farthest first.
    let splats: Data
    /// The photo the scene was made from (upright pixels), and its focal length in those pixels.
    let imageWidth: Int, imageHeight: Int
    let focal: Float
    /// Depths (metres) of the nearest splats (0.1 % quantile) and of the near tenth (10 %), which the camera aims at.
    let nearDepth: Float
    let focusDepth: Float

    var memoryBytes: Int { splats.count }

    /// From SHARP's raw output: Gaussians in its NDC space, where x and y are scaled by
    /// 2·focal/width and 2·focal/height of the photo, and z is metric depth.
    init(means: MLMultiArray, scales: MLMultiArray, quaternions: MLMultiArray, colors: MLMultiArray, opacities: MLMultiArray,
         imageWidth: Int, imageHeight: Int, focal: Float) throws {
        let total = opacities.count
        guard total > 0, means.count == total * 3, scales.count == total * 3, quaternions.count == total * 4, colors.count == total * 3
        else { throw SpatialError.modelFailed("unexpected output shapes") }
        let mean = try Self.floats(means), scale = try Self.floats(scales), quaternion = try Self.floats(quaternions)
        let color = try Self.floats(colors), opacity = try Self.floats(opacities)

        // NDC to metres: a diagonal stretch, applied to the positions and to each covariance (D Σ D).
        let unsqueeze = SIMD3<Float>(Float(imageWidth) / (2 * focal), Float(imageHeight) / (2 * focal), 1)
        var kept: [Int32] = []
        kept.reserveCapacity(total)
        var depths = [Float](repeating: 0, count: total)
        for index in 0..<total {
            let z = mean[index * 3 + 2]
            depths[index] = z
            // Invisible or behind the camera: dropped.
            if opacity[index] >= 1.0 / 255.0, z > 1e-3, z.isFinite { kept.append(Int32(index)) }
        }
        guard kept.count > 16 else { throw SpatialError.modelFailed("empty scene") }

        // Farthest first, by a radix sort on the depth's bits (positive floats sort as integers).
        let order = Self.sortedFarthestFirst(kept, depths: depths)

        var sample = kept.enumerated().compactMap { $0.offset % 16 == 0 ? depths[Int($0.element)] : nil }
        sample.sort()
        nearDepth = sample[min(sample.count - 1, Int(Float(sample.count - 1) * 0.001))]
        focusDepth = sample[min(sample.count - 1, Int(Float(sample.count - 1) * 0.1))]

        var data = Data(count: order.count * MemoryLayout<Splat>.stride)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Splat.self)
            for (slot, element) in order.enumerated() {
                let i = Int(element)
                let p = SIMD3(mean[i * 3], mean[i * 3 + 1], mean[i * 3 + 2]) * unsqueeze
                var q = simd_quatf(ix: quaternion[i * 4 + 1], iy: quaternion[i * 4 + 2], iz: quaternion[i * 4 + 3], r: quaternion[i * 4])
                let length = q.length
                q = length > 1e-8 ? q / length : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                let s = SIMD3(scale[i * 3], scale[i * 3 + 1], scale[i * 3 + 2])
                // Σ = (D R S)(D R S)ᵀ
                let m = simd_float3x3(diagonal: unsqueeze) * simd_float3x3(q) * simd_float3x3(diagonal: s)
                let c = m * m.transpose
                out[slot] = Splat(
                    position: (p.x, p.y, p.z),
                    covariance: (c[0, 0], c[1, 0], c[2, 0], c[1, 1], c[2, 1], c[2, 2]),
                    color: (Float16(color[i * 3]), Float16(color[i * 3 + 1]), Float16(color[i * 3 + 2]), Float16(opacity[i]))
                )
            }
        }
        count = order.count
        splats = data
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.focal = focal
    }

    /// A Core ML output as a plain row of floats.
    private static func floats(_ array: MLMultiArray) throws -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(count)) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.prefix(count).map(Float.init) }
        default:
            throw SpatialError.modelFailed("unexpected output type")
        }
    }

    private static func sortedFarthestFirst(_ indices: [Int32], depths: [Float]) -> [Int32] {
        var keys = indices.map { ~depths[Int($0)].bitPattern } // descending
        var values = indices
        var swapKeys = keys, swapValues = values
        for shift in stride(from: 0, to: 32, by: 8) {
            var counts = [Int](repeating: 0, count: 257)
            for key in keys { counts[Int((key >> UInt32(shift)) & 0xFF) + 1] += 1 }
            for bucket in 1..<257 { counts[bucket] += counts[bucket - 1] }
            for index in keys.indices {
                let bucket = Int((keys[index] >> UInt32(shift)) & 0xFF)
                let slot = counts[bucket]
                counts[bucket] += 1
                swapKeys[slot] = keys[index]
                swapValues[slot] = values[index]
            }
            swap(&keys, &swapKeys)
            swap(&values, &swapValues)
        }
        return values
    }
}

/// Recent scenes, in memory only (about 50 MB each).
@MainActor
enum GaussianCloudCache {
    private static var clouds: [(key: String, cloud: GaussianCloud)] = []
    private static let limit = 2

    static func cloud(for key: String) -> GaussianCloud? { clouds.first { $0.key == key }?.cloud }

    static func store(_ cloud: GaussianCloud, for key: String) {
        clouds.removeAll { $0.key == key }
        clouds.append((key, cloud))
        if clouds.count > limit { clouds.removeFirst(clouds.count - limit) }
    }

    static func removeAll() { clouds.removeAll() }
}
