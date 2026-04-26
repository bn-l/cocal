import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bn-l.codex-switcher", category: "CalibratorIcon")

struct CalibratorIcon: View {
    let calibrator: Double
    let sessionDeviation: Double
    let dailyDeviation: Double
    let dailyBudgetRemaining: Double
    let displayMode: MenuBarDisplayMode
    var isSessionActive = true
    var hasError = false
    var needsRestart = false

    /// Total icon edge in pixels.
    private static let iconSize: CGFloat = 18
    /// Pixel column reserved for the vertical "Codex" label on the left.
    private static let labelColumnWidth: CGFloat = CGFloat(CodexLabel.glyphWidth)
    /// Gap between the label column and the gauge area.
    private static let labelGap: CGFloat = 1
    /// Gauge area starts after the label column + gap.
    private static var gaugeOriginX: CGFloat { labelColumnWidth + labelGap }
    private static var gaugeWidth: CGFloat { iconSize - gaugeOriginX }

    var body: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            switch displayMode {
            case .calibrator: Image(nsImage: renderCalibrator())
            case .dualBar:    Image(nsImage: renderDualBar())
            }
        }
    }

    private func renderCalibrator() -> NSImage {
        let size = Self.iconSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderCalibrator: no CGContext available")
                return false
            }

            CodexLabel.draw(in: ctx, originX: 0, iconHeight: size, color: NSColor.labelColor.cgColor)

            if needsRestart {
                drawRestartGlyph(ctx: ctx, originX: Self.gaugeOriginX, width: Self.gaugeWidth, size: size)
                return true
            }

            let gaugeOriginX = Self.gaugeOriginX
            let gaugeWidth = Self.gaugeWidth
            let centerY = size / 2
            let barWidth = gaugeWidth * 0.8
            let barX = gaugeOriginX + (gaugeWidth - barWidth) / 2
            let maxExtent = size / 2

            let clamped = max(-1, min(1, calibrator))
            let magnitude = abs(clamped)
            let barHeight = CGFloat(magnitude) * maxExtent

            if barHeight > 0.5 {
                let color = UsageColor.cgColorFromCalibrator(calibrator)
                let barY: CGFloat = clamped >= 0 ? centerY : centerY - barHeight

                ctx.setFillColor(color)
                ctx.fill(CGRect(x: barX, y: barY, width: barWidth, height: barHeight))
            }

            // Center line spans the gauge area only — leaves the label column clean.
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: gaugeOriginX, y: centerY - 0.5, width: gaugeWidth, height: 1))

            drawArrow(ctx: ctx, value: calibrator, barX: barX, barWidth: barWidth, size: size)

            return true
        }
        image.isTemplate = false
        return image
    }

    private func renderDualBar() -> NSImage {
        let size = Self.iconSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderDualBar: no CGContext available")
                return false
            }

            CodexLabel.draw(in: ctx, originX: 0, iconHeight: size, color: NSColor.labelColor.cgColor)

            if needsRestart {
                drawRestartGlyph(ctx: ctx, originX: Self.gaugeOriginX, width: Self.gaugeWidth, size: size)
                return true
            }

            let gaugeOriginX = Self.gaugeOriginX
            let gaugeWidth = Self.gaugeWidth
            let gap: CGFloat = 1
            let barWidth = (gaugeWidth - gap) / 2
            let centerY = size / 2
            let maxExtent = size / 2

            // Left bar — session deviation
            if isSessionActive {
                let sClamped = max(-1, min(1, sessionDeviation))
                let sHeight = CGFloat(abs(sClamped)) * maxExtent
                if sHeight > 0.5 {
                    ctx.setFillColor(UsageColor.cgColorFromCalibrator(sClamped))
                    let barY: CGFloat = sClamped >= 0 ? centerY : centerY - sHeight
                    ctx.fill(CGRect(x: gaugeOriginX, y: barY, width: barWidth, height: sHeight))
                }
            }

            // Right bar — daily budget gauge
            let remaining = max(0, min(1, dailyBudgetRemaining))
            let gaugeHeight = max(remaining > 0 ? 1.0 : 0.0, CGFloat(remaining) * size)
            if gaugeHeight > 0.5 {
                let hue = CGFloat(remaining) * (120.0 / 360.0)
                let color = NSColor(hue: hue, saturation: 0.6, brightness: 0.925, alpha: 1.0).cgColor
                ctx.setFillColor(color)
                let gaugeY = (size - gaugeHeight) / 2
                ctx.fill(CGRect(x: gaugeOriginX + barWidth + gap, y: gaugeY, width: barWidth, height: gaugeHeight))
            }

            // Center line — left (session deviation) bar only
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: gaugeOriginX, y: centerY - 0.5, width: barWidth, height: 1))

            if isSessionActive {
                drawArrow(ctx: ctx, value: sessionDeviation, barX: gaugeOriginX, barWidth: barWidth, size: size)
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawRestartGlyph(ctx: CGContext, originX: CGFloat, width: CGFloat, size: CGFloat) {
        let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Needs restart")
        guard let symbol else { return }
        let edge = min(width, size)
        let rect = CGRect(
            x: originX + (width - edge) / 2,
            y: (size - edge) / 2,
            width: edge,
            height: edge
        )
        if let cg = symbol.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil) {
            ctx.saveGState()
            ctx.clip(to: rect, mask: cg)
            ctx.setFillColor(NSColor.systemOrange.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        }
    }

    private func drawArrow(ctx: CGContext, value: Double, barX: CGFloat, barWidth: CGFloat, size: CGFloat) {
        let clamped = max(-1, min(1, value))
        guard abs(clamped) > 0.15 else { return }

        let arrowHeight: CGFloat = 2
        ctx.setFillColor(NSColor.white.cgColor)

        if clamped > 0 {
            // Downward arrow at bottom edge (bar is above)
            ctx.move(to: CGPoint(x: barX + barWidth / 2, y: 0))
            ctx.addLine(to: CGPoint(x: barX, y: arrowHeight))
            ctx.addLine(to: CGPoint(x: barX + barWidth, y: arrowHeight))
        } else {
            // Upward arrow at top edge (bar is below)
            ctx.move(to: CGPoint(x: barX + barWidth / 2, y: size))
            ctx.addLine(to: CGPoint(x: barX, y: size - arrowHeight))
            ctx.addLine(to: CGPoint(x: barX + barWidth, y: size - arrowHeight))
        }

        ctx.closePath()
        ctx.fillPath()
    }
}
