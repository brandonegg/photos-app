import UIKit

/// The small capsule under the ··· button that turns the spatial scene on and off
/// (reference: the system viewer's control). Grey when off, a blue "SPATIAL SCENE" label
/// while the scene is being made, blue with white glyphs when on.
final class SpatialSceneBadge: UIControl {
    enum Mode: Equatable { case off, generating, on }

    private(set) var mode = Mode.off
    private let stack = UIStackView()
    private let icon = UIImageView(image: SpatialSceneBadge.glyph(side: 13))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.5, weight: .regular)))
    private let label = UILabel()

    private static let offFill = ViewerBadgeButton.fill
    private static let offBorder = ViewerBadgeButton.border
    private static let offGlyph = ViewerBadgeButton.glyph

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        icon.contentMode = .center
        chevron.contentMode = .center
        var text = AttributedString(String(localized: "SPATIAL SCENE"))
        text.font = .systemFont(ofSize: 10.5, weight: .semibold)
        text.kern = 0.3
        label.attributedText = NSAttributedString(text)
        label.textColor = .white
        for view in [icon, label, chevron] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(5, after: icon)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ViewerBadgeButton.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5.5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Spatial Scene")
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// Easier to hit than its 19 points suggest.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -13).contains(point)
    }

    override var isHighlighted: Bool {
        didSet { alphaWhenShown = isHighlighted ? 0.55 : 1 }
    }

    /// The viewer fades the badge with its other controls; pressing dims it on top of that.
    private var alphaWhenShown: CGFloat = 1 { didSet { stack.alpha = alphaWhenShown } }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = mode == .off ? Self.offBorder.resolvedColor(with: traitCollection).cgColor : UIColor.clear.cgColor
    }

    func set(_ mode: Mode, animated: Bool) {
        guard mode != self.mode else { return }
        self.mode = mode
        guard animated, window != nil else { return apply() }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.apply()
            self.superview?.layoutIfNeeded()
        }
    }

    private func apply() {
        let on = mode != .off
        backgroundColor = on ? .systemBlue : Self.offFill
        layer.borderWidth = on ? 0 : 1 / max(traitCollection.displayScale, 1)
        layer.borderColor = on ? UIColor.clear.cgColor : Self.offBorder.resolvedColor(with: traitCollection).cgColor
        let tint: UIColor = on ? .white : Self.offGlyph
        icon.tintColor = tint
        chevron.tintColor = tint
        label.isHidden = mode != .generating
        chevron.isHidden = mode == .generating
        accessibilityValue = switch mode {
        case .off: String(localized: "Off")
        case .generating: String(localized: "Creating")
        case .on: String(localized: "On")
        }
    }

    /// A rounded hexagon holding a small landscape (a sun over hills): drawn here, a template image.
    static func glyph(side: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            let center = CGPoint(x: side / 2, y: side / 2), radius = side * 0.49, line = max(side * 0.085, 1)
            // Point-up hexagon with rounded corners.
            let corners = (0..<6).map { index -> CGPoint in
                let angle = CGFloat(index) * .pi / 3 - .pi / 2
                return CGPoint(x: center.x + (radius - line / 2) * cos(angle), y: center.y + (radius - line / 2) * sin(angle))
            }
            let hexagon = UIBezierPath()
            let rounding = side * 0.09
            for index in 0..<6 {
                let current = corners[index], previous = corners[(index + 5) % 6], next = corners[(index + 1) % 6]
                func toward(_ point: CGPoint) -> CGPoint {
                    let dx = point.x - current.x, dy = point.y - current.y, length = max(hypot(dx, dy), 0.001)
                    return CGPoint(x: current.x + dx / length * rounding, y: current.y + dy / length * rounding)
                }
                let start = toward(previous), end = toward(next)
                if index == 0 { hexagon.move(to: start) } else { hexagon.addLine(to: start) }
                hexagon.addQuadCurve(to: end, controlPoint: current)
            }
            hexagon.close()
            UIColor.black.setStroke()
            UIColor.black.setFill()
            hexagon.lineWidth = line
            hexagon.lineJoinStyle = .round
            hexagon.stroke()

            // Hills across the lower half, kept inside the hexagon.
            UIGraphicsGetCurrentContext()?.saveGState()
            hexagon.addClip()
            let hills = UIBezierPath()
            // Two peaks: a small one on the left and a taller one to the right.
            hills.move(to: CGPoint(x: 0, y: side * 0.74))
            hills.addLine(to: CGPoint(x: side * 0.31, y: side * 0.59))
            hills.addLine(to: CGPoint(x: side * 0.45, y: side * 0.67))
            hills.addLine(to: CGPoint(x: side * 0.67, y: side * 0.46))
            hills.addLine(to: CGPoint(x: side, y: side * 0.74))
            hills.lineJoinStyle = .round
            hills.addLine(to: CGPoint(x: side, y: side))
            hills.addLine(to: CGPoint(x: 0, y: side))
            hills.close()
            hills.fill()
            UIGraphicsGetCurrentContext()?.restoreGState()

            // The sun.
            let sun = side * 0.095
            UIBezierPath(ovalIn: CGRect(x: side * 0.35 - sun, y: side * 0.36 - sun, width: sun * 2, height: sun * 2)).fill()
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// A soft band of light sweeping over the photo while its scene is being made.
final class SpatialShimmerView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = UIColor(red: 0.55, green: 0.45, blue: 1, alpha: 0.10)
        let glow = UIColor(red: 0.86, green: 0.82, blue: 1, alpha: 0.55).cgColor, clear = UIColor(white: 1, alpha: 0).cgColor
        gradient.colors = [clear, glow, clear]
        gradient.locations = [0.35, 0.5, 0.65]
        gradient.startPoint = CGPoint(x: 0, y: 0.35)
        gradient.endPoint = CGPoint(x: 1, y: 0.65)
        layer.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
        guard gradient.animation(forKey: "sweep") == nil, bounds.width > 0 else { return }
        if UIAccessibility.isReduceMotionEnabled {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 0.7
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            gradient.add(pulse, forKey: "sweep")
        } else {
            let sweep = CABasicAnimation(keyPath: "transform.translation.x")
            sweep.fromValue = -bounds.width
            sweep.toValue = bounds.width
            sweep.duration = 1.25
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sweep.repeatCount = .infinity
            gradient.add(sweep, forKey: "sweep")
        }
    }
}

/// From the photo on screen to a ready scene.
enum SpatialSceneFactory {
    private struct ImageBox: @unchecked Sendable { let image: CGImage }

    /// An upright, standard-range copy of the image, no bigger than the scene needs (Display P3).
    @MainActor
    static func upright(_ image: UIImage, longestSide: CGFloat = SpatialSceneBuilder.colorSide) -> CGImage? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > 0 else { return nil }
        let scale = min(1, longestSide / longest)
        let width = Int((image.size.width * image.scale * scale).rounded()), height = Int((image.size.height * image.scale * scale).rounded())
        guard width > 1, height > 1, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        return context.makeImage()
    }

    @MainActor
    static func scene(for image: UIImage) async throws -> SpatialScene {
        guard let upright = upright(image) else { throw SpatialError.noImage }
        return try await build(ImageBox(image: upright))
    }

    /// The SHARP scene (3D Gaussians) for a photo.
    @MainActor
    static func cloud(for image: UIImage) async throws -> GaussianCloud {
        guard let upright = upright(image, longestSide: CGFloat(GaussianPredictor.inputSide)) else { throw SpatialError.noImage }
        return try await buildCloud(ImageBox(image: upright))
    }

    @concurrent
    private static func buildCloud(_ box: ImageBox) async throws -> GaussianCloud {
        try await GaussianPredictor.shared.cloud(for: box.image)
    }

    @concurrent
    private static func build(_ box: ImageBox) async throws -> SpatialScene {
        let depth = try await DepthEstimator.shared.depth(of: box.image)
        try Task.checkCancellation()
        return try SpatialSceneBuilder.build(image: box.image, depth: depth)
    }
}
