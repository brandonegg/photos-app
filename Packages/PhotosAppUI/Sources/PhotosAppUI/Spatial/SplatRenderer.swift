import Core
import CoreGraphics
import Foundation
import Metal
import simd

/// Draws a `GaussianCloud` from a camera near where the photo was taken.
///
/// Each frame a compute pass projects every splat to the screen (its 3D shape becomes a 2D
/// ellipse, as in 3D Gaussian Splatting), then each is drawn as a small quad shaded with its
/// Gaussian falloff and blended farthest first. The colours are linear, as SHARP makes them,
/// and the blend happens in linear light (sRGB target), as in SHARP's own renderer.
@MainActor
final class SplatRenderer {
    static let shared = SplatRenderer()
    static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    /// How far the camera moves at full tilt, as SHARP measures it: the nearest things shift by
    /// this share of the photo's diagonal. (SHARP's own preview videos use 0.08.)
    static let maxDisparity: Float = 0.035
    /// The camera aims at a point no nearer than this (metres), as in SHARP's camera model.
    static let minFocusDepth: Float = 2
    /// Added to each projected ellipse (pixels²), so tiny splats still cover a pixel.
    static let lowPass: Float = 0.3

    struct Buffers {
        let splats: MTLBuffer, projected: MTLBuffer
        let count: Int
        let cloud: GaussianCloud
    }

    /// Where the camera is and which way it looks (world → camera rotation, rows right/down/front).
    struct Camera {
        var rotation: simd_float3x3
        var eye: SIMD3<Float>
    }

    private struct Uniforms {
        var rotation: simd_float3x3
        var eye: SIMD3<Float>
        var focal: SIMD2<Float>
        var center: SIMD2<Float>
        var viewport: SIMD2<Float>
        var lowPass: Float
        var count: UInt32
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let project: MTLComputePipelineState
    private let draw: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let kernel = library.makeFunction(name: "splat_project") else { return nil }
            project = try device.makeComputePipelineState(function: kernel)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "splat_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "splat_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            draw = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.ui.error("Splat shader: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func buffers(for cloud: GaussianCloud) -> Buffers? {
        guard let splats = cloud.splats.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let projected = device.makeBuffer(length: cloud.count * 24, options: .storageModePrivate)
        else { return nil }
        return Buffers(splats: splats, projected: projected, count: cloud.count, cloud: cloud)
    }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// The camera for a viewpoint. `look`: -1…1 each way (where the viewer is relative to straight on;
    /// positive x moves near things right, positive y moves them down). `dolly`: 0…1 moves the camera
    /// forward by that share of the distance to the nearest things.
    static func camera(for cloud: GaussianCloud, look: SIMD2<Float>, dolly: Float = 0) -> Camera {
        let w = Float(cloud.imageWidth) / cloud.focal, h = Float(cloud.imageHeight) / cloud.focal
        let offset = maxDisparity * (w * w + h * h).squareRoot() * cloud.nearDepth
        let eye = SIMD3<Float>(-look.x * offset, -look.y * offset, dolly * cloud.nearDepth)
        let target = SIMD3<Float>(0, 0, max(minFocusDepth, cloud.focusDepth))
        let front = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(front, SIMD3<Float>(0, -1, 0)))
        let down = simd_cross(front, right)
        return Camera(rotation: simd_float3x3(rows: [right, down, front]), eye: eye)
    }

    /// How much to zoom in so that, at full tilt, the edges of the scene stay out of view.
    static func edgeZoom(for cloud: GaussianCloud) -> Float {
        let w = Float(cloud.imageWidth) / cloud.focal, h = Float(cloud.imageHeight) / cloud.focal
        let shift = maxDisparity * (w * w + h * h).squareRoot() / min(w, h) // of the shorter half-side, roughly
        return 1 + min(0.2, shift * 1.4)
    }

    func encode(_ buffers: Buffers, camera: Camera, zoom: Float, size: SIMD2<Float>, pass: MTLRenderPassDescriptor, into commandBuffer: MTLCommandBuffer) {
        let cloud = buffers.cloud
        let focal = cloud.focal * size.x / Float(cloud.imageWidth) * zoom
        var uniforms = Uniforms(
            rotation: camera.rotation, eye: camera.eye, focal: SIMD2(focal, focal), center: size / 2,
            viewport: size, lowPass: Self.lowPass, count: UInt32(buffers.count)
        )
        if let compute = commandBuffer.makeComputeCommandEncoder() {
            compute.setComputePipelineState(project)
            compute.setBuffer(buffers.splats, offset: 0, index: 0)
            compute.setBuffer(buffers.projected, offset: 0, index: 1)
            compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            let width = project.threadExecutionWidth * 4
            compute.dispatchThreadgroups(MTLSize(width: (buffers.count + width - 1) / width, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(draw)
        encoder.setVertexBuffer(buffers.projected, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: buffers.count)
        encoder.endEncoding()
    }

    /// One frame as an image (tests and diagnostics).
    func image(_ buffers: Buffers, look: SIMD2<Float>, zoom: Float, width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor), let commandBuffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        encode(buffers, camera: Self.camera(for: buffers.cloud, look: look), zoom: zoom, size: SIMD2(Float(width), Float(height)), pass: pass, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Splat {
        packed_float3 position;
        float cov[6];
        float padding;
        half4 color;
    };

    struct Projected {
        float2 center;
        half2 axis1;
        half2 axis2;
        half4 color;
    };

    struct Uniforms {
        float3x3 rotation;
        float3 eye;
        float2 focal;
        float2 center;
        float2 viewport;
        float lowPass;
        uint count;
    };

    kernel void splat_project(device const Splat *splats [[buffer(0)]],
                              device Projected *projected [[buffer(1)]],
                              constant Uniforms &u [[buffer(2)]],
                              uint id [[thread_position_in_grid]]) {
        if (id >= u.count) return;
        Splat s = splats[id];
        Projected out;
        out.center = float2(-1e6);
        out.axis1 = half2(0.0h);
        out.axis2 = half2(0.0h);
        out.color = s.color;
        float3 p = u.rotation * (float3(s.position) - u.eye);
        if (p.z < 0.02) { projected[id] = out; return; }

        float3x3 world = float3x3(float3(s.cov[0], s.cov[1], s.cov[2]),
                                  float3(s.cov[1], s.cov[3], s.cov[4]),
                                  float3(s.cov[2], s.cov[4], s.cov[5]));
        float3x3 view = u.rotation * world * transpose(u.rotation);
        float iz = 1.0 / p.z;
        float2 center = u.focal * p.xy * iz + u.center;
        // The perspective projection, linearised at the splat (its Jacobian rows).
        float3 j0 = float3(u.focal.x * iz, 0.0, -u.focal.x * p.x * iz * iz);
        float3 j1 = float3(0.0, u.focal.y * iz, -u.focal.y * p.y * iz * iz);
        float a = dot(j0, view * j0) + u.lowPass;
        float b = dot(j0, view * j1);
        float c = dot(j1, view * j1) + u.lowPass;

        // The ellipse's axes: eigenvectors of the 2D covariance, each as long as one standard deviation.
        float mid = 0.5 * (a + c);
        float spread = sqrt(max(0.25 * (a - c) * (a - c) + b * b, 0.0));
        float l1 = mid + spread, l2 = max(mid - spread, 0.0);
        float2 v1 = abs(b) > 1e-12 ? normalize(float2(b, l1 - a)) : (a >= c ? float2(1.0, 0.0) : float2(0.0, 1.0));
        float2 v2 = float2(-v1.y, v1.x);
        float r1 = min(sqrt(l1), 600.0), r2 = min(sqrt(l2), 600.0);
        float reach = 3.0 * r1;
        if (center.x + reach < 0.0 || center.y + reach < 0.0 || center.x - reach > u.viewport.x || center.y - reach > u.viewport.y) {
            projected[id] = out;
            return;
        }
        out.center = center;
        out.axis1 = half2(v1 * r1);
        out.axis2 = half2(v2 * r2);
        projected[id] = out;
    }

    struct Fragment {
        float4 position [[position]];
        float2 local;
        half4 color;
    };

    vertex Fragment splat_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 device const Projected *projected [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
        Projected s = projected[iid];
        float2 corner = float2((vid & 1) ? 3.0 : -3.0, (vid & 2) ? 3.0 : -3.0);
        float2 pixel = s.center + corner.x * float2(s.axis1) + corner.y * float2(s.axis2);
        Fragment out;
        out.position = float4(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0, 0.0, 1.0);
        out.local = corner;
        out.color = s.color;
        return out;
    }

    fragment half4 splat_fragment(Fragment in [[stage_in]]) {
        float alpha = min(0.99, float(in.color.a) * exp(-0.5 * dot(in.local, in.local)));
        if (alpha < 1.0 / 255.0) discard_fragment();
        return half4(in.color.rgb * half(alpha), half(alpha));
    }
    """
}
