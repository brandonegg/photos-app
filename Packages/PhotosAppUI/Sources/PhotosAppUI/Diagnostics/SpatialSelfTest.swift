import CoreGraphics
import os
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import simd

/// Development aid: `-SpatialSelfTest`. Opens the newest Library photo in the viewer and checks
/// the spatial scene end to end: how long the depth model takes, the layers it builds, frames
/// drawn from several viewpoints (saved to Library/Caches/selftest), then the real button.
/// "SHOT name" lines mark moments worth a screenshot of the phone. Nothing is changed or uploaded.
@MainActor
enum SpatialSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-SpatialSelfTest") || isPortraitTest }
    /// `-PortraitSelfTest`: opens the newest Portrait photo on the iPhone and switches Portrait off and on.
    static var isPortraitTest: Bool { ProcessInfo.processInfo.arguments.contains("-PortraitSelfTest") }

    /// The newest photos on this iPhone taken with the depth effect.
    static func portraitLocalIDs() -> [String] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoDepthEffect.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 30
        var ids: [String] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    private static func runPortrait(viewer: ViewerViewController) async {
        var waited = 0
        while (viewer.spatialTestPage?.zoomView.imageView.image).map({ $0.size.width * $0.scale < 600 }) ?? true, waited < 150 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let page = viewer.spatialTestPage, let item = page.item else { say("no page"); return say("done") }
        let badge = viewer.portraitTestBadge
        if let localID = item.localID, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject {
            let resources = PHAssetResource.assetResources(for: asset)
            say("asset subtypes \(asset.mediaSubtypes.rawValue), resources \(resources.map { "\($0.type.rawValue):\($0.originalFilename)" }), adjusted \(asset.value(forKey: "hasAdjustments") as? Bool ?? false)")
        } else {
            say("item has no phone copy: localID \(item.localID ?? "nil")")
        }
        say("portrait badge shown \(!badge.isHidden), off \(badge.isOff), frame \(badge.convert(badge.bounds, to: viewer.view).integral)")
        let wasOff = PortraitSettings.isOff(item.id)
        try? await Task.sleep(for: .seconds(3))
        say("SHOT portrait-on")
        try? await Task.sleep(for: .seconds(4))
        let before = page.zoomView.imageView.image.flatMap { SpatialSceneFactory.upright($0) }
        badge.set(off: true)
        page.setPortraitOff(true)
        try? await Task.sleep(for: .seconds(4))
        let after = page.zoomView.imageView.image.flatMap { SpatialSceneFactory.upright($0) }
        if let before, let after { say(String(format: "portrait off differs from on by %.4f (blur removed shows as > 0)", difference(before, after))) }
        say("SHOT portrait-off")
        try? await Task.sleep(for: .seconds(4))
        badge.set(off: wasOff)
        page.setPortraitOff(wasOff)
        try? await Task.sleep(for: .seconds(3))
        say("restored: off \(PortraitSettings.isOff(item.id))")
        say("done")
    }

    static func say(_ text: String) { ScreenCapture.log("SPATIALTEST " + text) }

    static func run(viewer: ViewerViewController) async {
        if isPortraitTest { return await runPortrait(viewer: viewer) }
        say("model in this build: depth \(DepthEstimator.isAvailable), SHARP \(GaussianPredictor.isAvailable)")
        guard DepthEstimator.isAvailable || GaussianPredictor.isAvailable else { return say("done") }
        var waited = 0
        // Wait for the full preview, not the small placeholder.
        while (viewer.spatialTestPage?.zoomView.imageView.image).map({ $0.size.width * $0.scale < 600 }) ?? true, waited < 150 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let page = viewer.spatialTestPage, let image = page.zoomView.imageView.image else { say("no photo on screen"); return say("done") }
        say("photo \(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)), badge \(viewer.spatialTestBadge.mode), badge frame \(viewer.spatialTestBadge.frame.integral), alpha \(viewer.spatialTestBadge.alpha)")
        try? await Task.sleep(for: .seconds(2))
        say("SHOT off")
        try? await Task.sleep(for: .seconds(5))

        if GaussianPredictor.isAvailable {
            await runSharp(image: image)
        } else {
            await runDepth(image: image)
        }
        await runButton(viewer: viewer, page: page)
    }

    /// SHARP on its own, timed, with frames from several viewpoints.
    private static func runSharp(image: UIImage) async {
        do {
            let memoryBefore = os_proc_available_memory()
            var started = Date()
            let cloud = try await SpatialSceneFactory.cloud(for: image)
            let total = Date().timeIntervalSince(started)
            let load = await GaussianPredictor.shared.loadSeconds, predict = await GaussianPredictor.shared.predictSeconds, build = await GaussianPredictor.shared.buildSeconds
            say(String(format: "sharp: first scene %.2f s (model load %.2f s, predict %.2f s, splats %.2f s), %d splats, near %.2f m, focus %.2f m, %.0f MB, memory left %.0f → %.0f MB",
                       total, load, predict, build, cloud.count, cloud.nearDepth, cloud.focusDepth, Double(cloud.memoryBytes) / 1_048_576,
                       Double(memoryBefore) / 1_048_576, Double(os_proc_available_memory()) / 1_048_576))
            started = Date()
            _ = try await SpatialSceneFactory.cloud(for: image)
            say(String(format: "sharp: next scene %.2f s (predict %.2f s)", Date().timeIntervalSince(started), await GaussianPredictor.shared.predictSeconds))
            guard let renderer = SplatRenderer.shared, let buffers = renderer.buffers(for: cloud),
                  let upright = SpatialSceneFactory.upright(image, longestSide: CGFloat(GaussianPredictor.inputSide)) else { throw SpatialError.renderFailed }
            let width = cloud.imageWidth, height = cloud.imageHeight
            if let flat = renderer.image(buffers, look: .zero, zoom: 1, width: width, height: height) {
                save(flat, name: "sharp-straight")
                save(upright, name: "sharp-photo")
                say(String(format: "straight on at zoom 1 differs from the photo by %.4f (0 = identical)", difference(flat, upright)))
            }
            let zoom = SplatRenderer.edgeZoom(for: cloud)
            var frames: [String: CGImage] = [:]
            for (name, look) in [("centre", SIMD2<Float>(0, 0)), ("left", SIMD2<Float>(-1, 0)), ("right", SIMD2<Float>(1, 0)), ("up", SIMD2<Float>(0, -1)), ("down", SIMD2<Float>(0, 1))] {
                started = Date()
                guard let frame = renderer.image(buffers, look: look, zoom: zoom, width: width, height: height) else { continue }
                frames[name] = frame
                save(frame, name: "sharp-\(name)")
                say(String(format: "view %@: drawn in %.0f ms", name, Date().timeIntervalSince(started) * 1000))
            }
            if let left = frames["left"], let right = frames["right"], let up = frames["up"], let down = frames["down"] {
                say(String(format: "left vs right differ by %.4f, up vs down %.4f (parallax shows as > 0), zoom %.3f", difference(left, right), difference(up, down), zoom))
            }
        } catch {
            say("sharp pipeline failed: \(error)")
        }
    }

    /// The depth-map pipeline on its own, timed.
    private static func runDepth(image: UIImage) async {
        do {
            guard let upright = SpatialSceneFactory.upright(image) else { throw SpatialError.noImage }
            var started = Date()
            let depth = try await DepthEstimator.shared.depth(of: upright)
            let first = Date().timeIntervalSince(started)
            let load = await DepthEstimator.shared.loadSeconds
            started = Date()
            _ = try await DepthEstimator.shared.depth(of: upright)
            let second = Date().timeIntervalSince(started)
            say(String(format: "depth: model load %.2f s, first estimate %.2f s (with load), next %.3f s, map %d×%d, relief %.2f", load, first, second, depth.width, depth.height, depth.relief))
            started = Date()
            let scene = try SpatialSceneBuilder.build(image: upright, depth: depth)
            say(String(format: "scene: built in %.2f s, photo %d×%d, layers %d×%d, focus %.2f, strength %.2f, %.1f MB", Date().timeIntervalSince(started), scene.width, scene.height, scene.auxWidth, scene.auxHeight, scene.focus, scene.strength, Double(scene.memoryBytes) / 1_048_576))
            save(grey: scene.depth, width: scene.auxWidth, height: scene.auxHeight, name: "depth")
            save(grey: scene.backDepth, width: scene.auxWidth, height: scene.auxHeight, name: "back-depth")
            save(rgba: scene.backColor, width: scene.auxWidth, height: scene.auxHeight, name: "back-color")
            guard let renderer = SpatialRenderer.shared, let textures = renderer.textures(for: scene) else { throw SpatialError.renderFailed }
            let width = scene.width / 2, height = scene.height / 2
            guard let flat = renderer.image(textures, look: .zero, zoom: 1, width: scene.width, height: scene.height) else { throw SpatialError.renderFailed }
            say(String(format: "straight on at zoom 1 differs from the photo by %.4f (0 = identical)", difference(flat, upright)))
            var frames: [String: CGImage] = [:]
            for (name, look) in [("centre", SIMD2<Float>(0, 0)), ("left", SIMD2<Float>(-1, 0)), ("right", SIMD2<Float>(1, 0)), ("up", SIMD2<Float>(0, -1)), ("down", SIMD2<Float>(0, 1))] {
                started = Date()
                guard let frame = renderer.image(textures, look: look, zoom: SpatialRenderer.activeZoom, width: width, height: height) else { continue }
                frames[name] = frame
                save(frame, name: "view-\(name)")
                say(String(format: "view %@: drawn in %.0f ms", name, Date().timeIntervalSince(started) * 1000))
            }
            if let left = frames["left"], let right = frames["right"], let centre = frames["centre"], let up = frames["up"], let down = frames["down"] {
                say(String(format: "left vs right differ by %.4f, up vs down %.4f, centre vs left %.4f (parallax shows as > 0)", difference(left, right), difference(up, down), difference(centre, left)))
            }
        } catch {
            say("pipeline failed: \(error)")
        }
    }

    private static func runButton(viewer: ViewerViewController, page: ViewerPageCell) async {
        // The label shown while a scene is made (it normally passes in a fraction of a second).
        viewer.spatialTestBadge.set(.generating, animated: false)
        viewer.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        say("SHOT label")
        try? await Task.sleep(for: .seconds(4))
        viewer.spatialTestBadge.set(.off, animated: false)
        // Start the button from cold, as a first use would.
        await DepthEstimator.shared.unload()
        await GaussianPredictor.shared.unload()
        GaussianCloudCache.removeAll()
        SpatialSceneCache.removeAll()
        var waited = 0

        // The real button.
        viewer.spatialTestTap()
        say("tapped: badge \(viewer.spatialTestBadge.mode)")
        try? await Task.sleep(for: .milliseconds(450))
        say("SHOT generating")
        while viewer.spatialTestBadge.mode != .on, waited < 1200 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        say("badge \(viewer.spatialTestBadge.mode) after \(waited * 100) ms, scene view \(page.spatialSceneView != nil), badge frame \(viewer.spatialTestBadge.frame.integral)")
        try? await Task.sleep(for: .seconds(2))
        if let view = page.spatialSceneView {
            for (name, look) in [("on-centre", SIMD2<Float>(0, 0)), ("on-left", SIMD2<Float>(-1, 0)), ("on-right", SIMD2<Float>(1, 0))] {
                view.manualLook = look
                try? await Task.sleep(for: .milliseconds(900))
                say("SHOT \(name)")
                try? await Task.sleep(for: .seconds(5))
            }
            say(String(format: "drawing: GPU %.1f ms a frame, scale %.0f×, size %d×%d", view.averageGPUTime * 1000, view.contentScaleFactor, Int(view.drawableSize.width), Int(view.drawableSize.height)))
            view.manualLook = nil
        }
        viewer.spatialTestTap()
        try? await Task.sleep(for: .seconds(1))
        say("off again: badge \(viewer.spatialTestBadge.mode), scene view \(page.spatialSceneView != nil)")
        say("SHOT off-again")
        try? await Task.sleep(for: .seconds(4))
        say("done")
    }

    /// Mean absolute difference (0…1) between two images at a small common size.
    private static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func small(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: 96 * 96 * 4)
            if let context = CGContext(data: &pixels, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                       space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
            }
            return pixels
        }
        let pa = small(a), pb = small(b)
        var sum = 0
        for index in 0..<(96 * 96) { for channel in 0..<3 { sum += abs(Int(pa[index * 4 + channel]) - Int(pb[index * 4 + channel])) } }
        return Double(sum) / Double(96 * 96 * 3 * 255)
    }

    private static func save(_ image: CGImage, name: String) {
        guard let destination = CGImageDestinationCreateWithURL(ScreenCapture.folder.appending(path: "spatial-\(name).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func save(grey: Data, width: Int, height: Int, name: String) {
        guard let provider = CGDataProvider(data: grey as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        save(image, name: name)
    }

    private static func save(rgba: Data, width: Int, height: Int, name: String) {
        guard let provider = CGDataProvider(data: rgba as CFData), let space = CGColorSpace(name: CGColorSpace.displayP3),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        save(image, name: name)
    }
}
