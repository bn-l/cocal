import Testing
import AppKit
import CoreGraphics
@testable import CodexSwitcher

@Suite("CodexLabel")
struct CodexLabelTests {

    /// Render the label into a tightly-fitting bitmap context and return raw
    /// alpha values per pixel, indexed by `[y][x]` with y=0 at the **top**.
    /// Default iconHeight matches `CodexLabel.totalHeight` so every glyph
    /// pixel survives the rasterization.
    private func render(iconHeight: CGFloat = CodexLabel.totalHeight, originX: CGFloat = 0) -> [[UInt8]] {
        let width = Int(originX) + CodexLabel.glyphWidth + 1
        let height = Int(iconHeight)
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        pixels.withUnsafeMutableBytes { rawBuf in
            let ptr = rawBuf.baseAddress!
            let cs = CGColorSpaceCreateDeviceGray()
            let ctx = CGContext(
                data: ptr,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            // Black background then draw label in white so any nonzero byte = pixel set.
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CodexLabel.draw(in: ctx, originX: originX, iconHeight: iconHeight, color: CGColor(gray: 1, alpha: 1))
        }

        // CGBitmapContext stores its buffer in screen order: row 0 of the
        // backing bytes corresponds to the *top* row of the image, regardless
        // of the y-up coordinate system used by drawing calls.
        var grid = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: height)
        for y in 0..<height {
            for x in 0..<width {
                grid[y][x] = pixels[y * bytesPerRow + x]
            }
        }
        return grid
    }

    private static let totalLitPixels: Int = 5 + 8 + 6 + 8 + 5  // C O D E X, pre-counted

    @Test("Total lit pixel count matches glyph definitions (32)")
    func litPixelCount() {
        let grid = render()
        var lit = 0
        for row in grid {
            for px in row where px > 128 { lit += 1 }
        }
        #expect(lit == Self.totalLitPixels)
    }

    @Test("Label sits inside the 3px-wide left column")
    func columnContainment() {
        let grid = render()
        for (y, row) in grid.enumerated() {
            for x in 0..<row.count where row[x] > 128 {
                #expect(x >= 0 && x < CodexLabel.glyphWidth, "Lit pixel outside label column at x=\(x), y=\(y)")
            }
        }
    }

    @Test("Label is vertically centered in a larger icon (1px padding top/bottom)")
    func verticalCentering() {
        // 21px canvas, 19px label → 1px padding on each side.
        let grid = render(iconHeight: 21)
        var firstLitRow: Int?
        var lastLitRow: Int?
        for (y, row) in grid.enumerated() {
            if row.contains(where: { $0 > 128 }) {
                if firstLitRow == nil { firstLitRow = y }
                lastLitRow = y
            }
        }
        #expect(firstLitRow == 1)  // top padding
        #expect(lastLitRow == 19)  // bottom-most lit row of X glyph (after 1px pad)
    }

    @Test("Top row of C-glyph: pixels (0,top) and (1,top) lit, (2,top) dark")
    func cGlyphTopRow() {
        // Render in a canvas matching totalHeight so the C glyph sits at row 0.
        let grid = render(iconHeight: CodexLabel.totalHeight)
        let topRow = 0
        #expect(grid[topRow][0] > 128)
        #expect(grid[topRow][1] > 128)
        #expect(grid[topRow][2] < 128)
    }

    @Test("Middle row of X-glyph: only column 1 lit")
    func xGlyphMiddleRow() {
        // Render in a canvas matching totalHeight (19px).
        // X is letter index 4; with 4px stride it starts at row 16. Middle = 17.
        let grid = render(iconHeight: CodexLabel.totalHeight)
        let xMiddle = 16 + 1
        #expect(grid[xMiddle][0] < 128)
        #expect(grid[xMiddle][1] > 128)
        #expect(grid[xMiddle][2] < 128)
    }

    @Test("Drawing with originX > 0 shifts label right")
    func originXShift() {
        let grid = render(originX: 4)
        for (y, row) in grid.enumerated() {
            for x in 0..<row.count where row[x] > 128 {
                #expect(x >= 4 && x < 4 + CodexLabel.glyphWidth, "Pixel at x=\(x), y=\(y) outside shifted column")
            }
        }
    }

    /// Issue 7: the label was 15px tall in an 18px icon (5 letters × 3 px,
    /// no spacing). The user reported the letters needed breathing room
    /// between them and that the label should claim the full vertical space
    /// available. Math: 5 letters × 3 px + 4 gaps × 1 px = 19 px → bump
    /// iconSize so this fits, and verify the label uses every pixel of it.
    @Test("totalHeight uses full available space (5 letters × 3 + 4 inter-letter gaps × 1)")
    func totalHeightWithSpacing() {
        // 5 × 3 + 4 × 1 = 19. Anything less means there's slack.
        #expect(CodexLabel.totalHeight == 19)
    }

    @Test("Inter-letter gaps actually exist (rows between each letter contain no lit pixels)")
    func gapRowsAreEmpty() {
        // Render at iconHeight = totalHeight so the label fills the whole icon.
        let height = Int(CodexLabel.totalHeight)
        let grid = render(iconHeight: CGFloat(height))
        // Letter-N occupies rows [N*4 .. N*4+2]; row N*4+3 is the gap (for N=0..3).
        for letterIndex in 0..<4 {
            let gapRow = letterIndex * (CodexLabel.glyphHeight + 1) + CodexLabel.glyphHeight
            for x in 0..<CodexLabel.glyphWidth {
                #expect(grid[gapRow][x] < 128, "Gap row \(gapRow) col \(x) unexpectedly lit")
            }
        }
    }

    @Test("Label spans the full icon vertically when iconHeight == totalHeight")
    func fillsAvailableVerticalSpace() {
        let height = Int(CodexLabel.totalHeight)
        let grid = render(iconHeight: CGFloat(height))
        // First and last lit rows must touch the top and bottom edges.
        var firstLit: Int?
        var lastLit: Int?
        for (y, row) in grid.enumerated() {
            if row.contains(where: { $0 > 128 }) {
                if firstLit == nil { firstLit = y }
                lastLit = y
            }
        }
        #expect(firstLit == 0)
        #expect(lastLit == height - 1)
    }
}
