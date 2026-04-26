import Testing
import AppKit
import CoreGraphics
@testable import CodexSwitcher

@Suite("CodexLabel")
struct CodexLabelTests {

    /// Render the label into a tightly-fitting bitmap context and return raw
    /// alpha values per pixel, indexed by `[y][x]` with y=0 at the **top**.
    private func render(iconHeight: CGFloat = 18, originX: CGFloat = 0) -> [[UInt8]] {
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

    @Test("Label is vertically centered in 18px icon (1.5px breathing room)")
    func verticalCentering() {
        let grid = render(iconHeight: 18)
        // Find first and last row with any lit pixel.
        var firstLitRow: Int?
        var lastLitRow: Int?
        for (y, row) in grid.enumerated() {
            if row.contains(where: { $0 > 128 }) {
                if firstLitRow == nil { firstLitRow = y }
                lastLitRow = y
            }
        }
        #expect(firstLitRow == 2)  // 1.5px breathing rounds to row index 2 (top edge of letter)
        #expect(lastLitRow == 16)  // bottom-most lit row of X glyph
    }

    @Test("Top row of C-glyph: pixels (0,top) and (1,top) lit, (2,top) dark")
    func cGlyphTopRow() {
        let grid = render()
        let topRow = 2  // matches verticalCentering
        #expect(grid[topRow][0] > 128)
        #expect(grid[topRow][1] > 128)
        #expect(grid[topRow][2] < 128)
    }

    @Test("Middle row of X-glyph (last letter, row 1): only column 1 lit")
    func xGlyphMiddleRow() {
        let grid = render()
        // X starts at letterIndex=4. Top of X = topRow + 4*3 = 2+12 = 14. Middle = 15.
        let xMiddle = 14 + 1
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

    @Test("totalHeight equals 15 (5 letters × 3 rows)")
    func totalHeightConstant() {
        #expect(CodexLabel.totalHeight == 15)
    }
}
