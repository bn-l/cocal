import AppKit
import CoreGraphics

/// Hand-encoded mcufont-style 3w × 3h bitmap glyphs for the vertical "CODEX"
/// menu-bar label. Pixels are placed by hand, no font subsetter required.
///
/// Layout in the icon: a 3px-wide column on the left, 5 letters stacked top→
/// bottom (C, O, D, E, X), each 3px tall, with a 1px gap between adjacent
/// letters so they don't read as a smear. Total label height = 5×3 + 4×1 = 19
/// px, which is exactly the 19px iconSize in `CalibratorIcon` — the label
/// claims the full vertical space available to it.
enum CodexLabel {
    static let glyphWidth: Int = 3
    static let glyphHeight: Int = 3
    static let letterCount: Int = 5
    /// Vertical gap between adjacent letters, in pixels.
    static let letterGap: Int = 1
    /// Pixels each letter "occupies" in the stacking grid (its own height plus
    /// the gap below it). The last letter has no gap below.
    private static let stride: Int = glyphHeight + letterGap
    /// Total label height in pixels: N letters × glyphHeight + (N-1) gaps.
    static var totalHeight: CGFloat {
        CGFloat(letterCount * glyphHeight + (letterCount - 1) * letterGap)
    }

    /// Each glyph: 3 rows of 3 bits, MSB = leftmost pixel. Glyphs are listed
    /// top-to-bottom in the rendered label.
    private static let glyphs: [[UInt8]] = [
        // C
        [0b110, 0b100, 0b110],
        // O
        [0b111, 0b101, 0b111],
        // D
        [0b110, 0b101, 0b110],
        // E
        [0b111, 0b110, 0b111],
        // X
        [0b101, 0b010, 0b101],
    ]

    /// Draw the label into `ctx`. `originX` is the x-coordinate of the label's
    /// left edge; the label fills `glyphWidth` pixels horizontally and centers
    /// vertically within `iconHeight`.
    static func draw(
        in ctx: CGContext,
        originX: CGFloat,
        iconHeight: CGFloat,
        color: CGColor
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // 3×3 glyphs need pixel-perfect rectangles. Anti-aliasing turns 1×1
        // rects into smudged grays that don't read at menu-bar size.
        ctx.setShouldAntialias(false)
        ctx.setFillColor(color)
        // CGContext y=0 is at the bottom. We want the label drawn top-down, so
        // start from the top of the centered band and step down per pixel row.
        // Snap to integer pixel rows — odd-pixel breathing room (e.g. 1.5px in
        // an 18px icon) would otherwise straddle two pixel rows.
        let topY = floor((iconHeight + totalHeight) / 2)
        for (letterIndex, rows) in glyphs.enumerated() {
            for (rowIndex, rowBits) in rows.enumerated() {
                // y for this row, where row 0 is the top of the letter. Stride
                // includes the inter-letter gap so each letter slot is 4px tall
                // (3px glyph + 1px breathing room below).
                let pixelY = topY - CGFloat(letterIndex * stride + rowIndex + 1)
                for col in 0..<glyphWidth {
                    let bit = (rowBits >> (glyphWidth - 1 - col)) & 0b1
                    if bit == 1 {
                        ctx.fill(CGRect(
                            x: originX + CGFloat(col),
                            y: pixelY,
                            width: 1,
                            height: 1
                        ))
                    }
                }
            }
        }
    }
}
