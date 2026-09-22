import CoreImage
import SwiftUI
import UIKit

/// Dominant hue of a piece of artwork, stored raw so it can be conditioned per color scheme at
/// render time — a sheet that flips appearance keeps the same per-title identity.
nonisolated struct DominantTint: Equatable, Sendable {
    let hue: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat

    /// The tint as it should be drawn in `scheme`.
    /// - Dark: saturation clamped up so a washed-out poster still reads as a color, brightness
    ///   held in a narrow deep band so a bright poster doesn't blow out the background and a neon
    ///   one doesn't scream.
    /// - Light: a pastel of the same hue — a deep color on a light mesh goes muddy, a pastel can
    ///   be washed over it at real opacity. Saturation is held a notch above the mesh's own so the
    ///   wash reads as *that title's* color rather than more lilac, and brightness is capped just
    ///   under white so it never goes lighter than the page it sits on.
    func color(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            Color(hue: hue, saturation: max(saturation, 0.55), brightness: min(max(brightness, 0.38), 0.55))
        default:
            Color(hue: hue, saturation: min(max(saturation, 0.40), 0.60), brightness: min(max(brightness, 0.84), 0.93))
        }
    }
}

extension UIImage {
    /// `CIContext` is expensive to build and documented as thread-safe, so every extraction shares
    /// one instead of spinning up a render context per poster.
    private nonisolated static let dominantTintContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Dominant color of the image for use as a per-title accent tint (see `HeaderImageView`).
    /// `CIAreaAverage` over the image extent is the cheap, standard approach to a "dominant"
    /// color — good enough for a background wash, not a palette.
    /// Safe to call off the main actor — the module defaults to main-actor isolation, so this is
    /// explicitly `nonisolated`.
    nonisolated func dominantTint() -> DominantTint? {
        guard let ciImage = CIImage(image: self) else { return nil }

        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        guard
            let filter = CIFilter(
                name: "CIAreaAverage",
                parameters: [
                    kCIInputImageKey: ciImage,
                    kCIInputExtentKey: CIVector(cgRect: extent),
                ]
            ),
            let outputImage = filter.outputImage
        else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        Self.dominantTintContext.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let red = CGFloat(bitmap[0]) / 255
        let green = CGFloat(bitmap[1]) / 255
        let blue = CGFloat(bitmap[2]) / 255

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return DominantTint(hue: hue, saturation: saturation, brightness: brightness)
    }
}

extension Color {
    /// Linear RGB mix of `self` with `other`; `amount` is `other`'s share (0 = all `self`,
    /// 1 = all `other`). Used to blend a per-title tint into `DesignTokens.Colors.backgroundBase`
    /// without ever fully replacing it.
    func mixed(with other: Color, amount: CGFloat) -> Color {
        let a = UIColor(self)
        let b = UIColor(other)

        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)

        let t = min(max(amount, 0), 1)
        return Color(
            red: ar + (br - ar) * t,
            green: ag + (bg - ag) * t,
            blue: ab + (bb - ab) * t,
            opacity: aa + (ba - aa) * t
        )
    }
}
