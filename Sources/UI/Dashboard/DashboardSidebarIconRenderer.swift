import AppKit

/// Rasterizes BalanceBar's sidebar artwork once per appearance and display scale.
@MainActor
final class DashboardSidebarIconRenderer {
    static let shared = DashboardSidebarIconRenderer()
    static let tileSize: CGFloat = 20
    // Space around the tile keeps its shadow inside the bitmap.
    static let imageSize: CGFloat = 24

    private struct Key: Hashable {
        let section: DashboardSection
        let appearance: NSAppearance.Name
        let scale: CGFloat
        let usesDarkPalette: Bool
    }

    private var images: [Key: NSImage] = [:]

    func image(
        for section: DashboardSection,
        appearance: NSAppearance,
        scale: CGFloat,
        usesDarkIcons: Bool
    ) -> NSImage {
        let dark = usesDarkIcons && appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = Key(section: section, appearance: appearance.name, scale: scale, usesDarkPalette: dark)
        if let image = images[key] { return image }

        let size = NSSize(width: Self.imageSize, height: Self.imageSize)
        let pixels = Int((size.width * scale).rounded())
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(pixels) / size.width, y: CGFloat(pixels) / size.height)
        let tile = CGRect(x: 2, y: 2, width: Self.tileSize, height: Self.tileSize)
        appearance.performAsCurrentDrawingAppearance {
            if section == .about {
                BalanceBarAppIcon.image().draw(in: tile.insetBy(dx: -0.75, dy: -0.75))
            } else {
                drawTile(tile, section: section, dark: dark, scale: CGFloat(pixels) / size.width, in: context)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        images[key] = image
        return image
    }

    private func drawTile(_ rect: CGRect, section: DashboardSection, dark: Bool, scale: CGFloat, in context: CGContext) {
        let base = dark ? NSColor(white: 0.085, alpha: 1) : section.chipColor
        let top = dark ? NSColor(white: 0.115, alpha: 1) : (base.highlight(withLevel: 0.18) ?? base)
        let bottom = dark ? NSColor(white: 0.07, alpha: 1) : (base.shadow(withLevel: 0.08) ?? base)
        let tile = CGMutablePath()
        // A continuous curve joins each edge without the curvature jump of a circular corner.
        let edge: CGFloat = 5
        let shoulder: CGFloat = 1.8
        tile.move(to: CGPoint(x: edge, y: 0))
        tile.addLine(to: CGPoint(x: 20 - edge, y: 0))
        tile.addCurve(to: CGPoint(x: 20, y: edge), control1: CGPoint(x: 20 - shoulder, y: 0), control2: CGPoint(x: 20, y: shoulder))
        tile.addLine(to: CGPoint(x: 20, y: 20 - edge))
        tile.addCurve(to: CGPoint(x: 20 - edge, y: 20), control1: CGPoint(x: 20, y: 20 - shoulder), control2: CGPoint(x: 20 - shoulder, y: 20))
        tile.addLine(to: CGPoint(x: edge, y: 20))
        tile.addCurve(to: CGPoint(x: 0, y: 20 - edge), control1: CGPoint(x: shoulder, y: 20), control2: CGPoint(x: 0, y: 20 - shoulder))
        tile.addLine(to: CGPoint(x: 0, y: edge))
        tile.addCurve(to: CGPoint(x: edge, y: 0), control1: CGPoint(x: 0, y: shoulder), control2: CGPoint(x: shoulder, y: 0))
        tile.closeSubpath()

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -0.75), blur: 1.5,
                          color: NSColor(white: 0, alpha: dark ? 0.35 : 0.2).cgColor)
        context.setFillColor(base.cgColor)
        context.addPath(tile)
        context.fillPath()
        context.restoreGState()
        context.addPath(tile)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [bottom.cgColor, top.cgColor] as CFArray, locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: rect.height), options: [])
        }

        context.setStrokeColor(NSColor(white: 1, alpha: dark ? 0.16 : 0.18).cgColor)
        context.setLineWidth(1)
        context.addPath(tile)
        context.strokePath()

        if let symbol = rasterizedSymbol(section, dark: dark, scale: scale) {
            let x = ((rect.width * scale - CGFloat(symbol.width)) / 2).rounded(.down)
            let y = ((rect.height * scale - CGFloat(symbol.height)) / 2).rounded(.down)
            if !dark {
                context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 0.5,
                                  color: NSColor(white: 0, alpha: 0.12).cgColor)
            }
            context.draw(symbol, in: CGRect(x: x / scale, y: y / scale,
                                            width: CGFloat(symbol.width) / scale,
                                            height: CGFloat(symbol.height) / scale))
        }
        context.restoreGState()
    }

    private func rasterizedSymbol(_ section: DashboardSection, dark: Bool, scale: CGFloat) -> CGImage? {
        let name: String
        let weight: NSFont.Weight
        let fraction: CGFloat
        switch section {
        case .general: (name, weight, fraction) = ("gearshape.fill", .regular, 0.75)
        case .menuBar: (name, weight, fraction) = ("rectangle.topthird.inset.filled", .medium, 0.74)
        case .menu: (name, weight, fraction) = ("line.3.horizontal", .semibold, 0.70)
        case .notifications: (name, weight, fraction) = ("bell.fill", .regular, 0.70)
        case .advanced: (name, weight, fraction) = ("slider.horizontal.3", .semibold, 0.74)
        case .about: return nil
        }
        let chipColor = section.chipColor
        let darkColor = chipColor == .systemGray ? NSColor(white: 0.58, alpha: 1) : chipColor
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.tileSize * fraction, weight: weight)
            .applying(.init(paletteColors: [dark ? darkColor : .white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        symbol.isTemplate = false

        // Measure at a higher resolution so asymmetric SF Symbol padding and
        // antialiasing do not shift the final placement by a device pixel.
        let measurementScale = scale * 4
        let pixels = Int(ceil(Self.imageSize * measurementScale))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.scaleBy(x: measurementScale, y: measurementScale)
        symbol.draw(in: CGRect(origin: CGPoint(x: 2, y: 2), size: symbol.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData, let rendered = bitmap.cgImage else { return nil }
        var minX = pixels
        var minY = pixels
        var maxX = -1
        var maxY = -1
        for y in 0..<pixels {
            for x in 0..<pixels where data[y * bitmap.bytesPerRow + x * 4 + 3] >= 32 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = rendered.cropping(to: bounds) else { return nil }

        let pixelScale = (Self.tileSize * fraction * scale).rounded() / max(bounds.width, bounds.height)
        let width = Int((bounds.width * pixelScale).rounded())
        let height = Int((bounds.height * pixelScale).rounded())
        guard let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        output.interpolationQuality = .high
        output.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return output.makeImage()
    }
}
