import CoreImage
import SwiftUI
import UIKit

extension UIImage {
    /// Dominant color of the image, conditioned for use as a per-title accent tint in a dark UI
    /// (see `HeaderImageView`). `CIAreaAverage` over the image extent is the cheap, standard
    /// approach to a "dominant" color — good enough for a background wash, not a palette.
    /// Safe to call off the main actor — the module defaults to main-actor isolation, so this is
    /// explicitly `nonisolated`.
    nonisolated func dominantColor() -> Color? {
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
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
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

        // Condition for a dark sheet: clamp saturation up so a washed-out poster still reads as
        // a color, and clamp brightness into a narrow deep-tint band so a bright/white poster
        // doesn't blow out the background and a neon one doesn't scream.
        let clampedSaturation = max(saturation, 0.55)
        let clampedBrightness = min(max(brightness, 0.38), 0.55)

        return Color(hue: hue, saturation: clampedSaturation, brightness: clampedBrightness)
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
