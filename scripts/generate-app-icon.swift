#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let packagingDir = rootDir.appendingPathComponent("apps/macos-console/Packaging", isDirectory: true)
try fileManager.createDirectory(at: packagingDir, withIntermediateDirectories: true)

func makeBitmapContext(width: Int, height: Int) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("Failed to create CGContext \(width)x\(height)")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func savePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Failed to create CGImageDestination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Failed to finalize PNG at \(url.path)")
    }
}

func drawSquirclePath(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
    return path
}

func renderAppIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = makeBitmapContext(width: size, height: size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // HIG macOS icon inset (~9.7% margin on each edge for shadow & rounded squircle)
    let margin = s * 0.095
    let cardRect = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let cornerRadius = cardRect.width * 0.2237
    let squircle = drawSquirclePath(rect: cardRect, cornerRadius: cornerRadius)

    // Outer ambient shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.018),
        blur: s * 0.045,
        color: CGColor(red: 0.02, green: 0.03, blue: 0.08, alpha: 0.52)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.10, blue: 0.24, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clipped card gradient background
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgColors = [
        CGColor(red: 0.055, green: 0.075, blue: 0.180, alpha: 1.0),
        CGColor(red: 0.115, green: 0.155, blue: 0.365, alpha: 1.0),
        CGColor(red: 0.055, green: 0.205, blue: 0.320, alpha: 1.0),
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
            options: []
        )
    }

    // Subtle glowing cyan-indigo aura in center
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let auraColors = [
        CGColor(red: 0.12, green: 0.72, blue: 0.90, alpha: 0.34),
        CGColor(red: 0.38, green: 0.32, blue: 0.96, alpha: 0.14),
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0),
    ] as CFArray
    if let auraGrad = CGGradient(colorsSpace: colorSpace, colors: auraColors, locations: [0.0, 0.45, 1.0]) {
        ctx.drawRadialGradient(
            auraGrad,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: cardRect.width * 0.52,
            options: []
        )
    }

    // Precision inner glass silicon tile
    let coreSize = cardRect.width * 0.58
    let coreRect = CGRect(
        x: center.x - coreSize / 2.0,
        y: center.y - coreSize / 2.0,
        width: coreSize,
        height: coreSize
    )
    let corePath = drawSquirclePath(rect: coreRect, cornerRadius: coreSize * 0.24)
    ctx.saveGState()
    ctx.addPath(corePath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.fillPath()
    ctx.addPath(corePath)
    ctx.setStrokeColor(CGColor(red: 0.45, green: 0.88, blue: 1.0, alpha: 0.45))
    ctx.setLineWidth(max(1.0, s * 0.009))
    ctx.strokePath()
    ctx.restoreGState()

    // 5-bar harmonic neural voice waveform inside the silicon tile
    let heights: [CGFloat] = [0.24, 0.44, 0.64, 0.48, 0.26]
    let barWidth = max(2.0, coreSize * 0.095)
    let barSpacing = coreSize * 0.155
    let totalW = CGFloat(heights.count - 1) * barSpacing + barWidth
    let startX = center.x - totalW / 2.0

    for (idx, hRatio) in heights.enumerated() {
        let bh = max(barWidth, coreSize * hRatio)
        let bx = startX + CGFloat(idx) * barSpacing
        let by = center.y - bh / 2.0
        let barRect = CGRect(x: bx, y: by, width: barWidth, height: bh)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2.0, cornerHeight: barWidth / 2.0, transform: nil)

        ctx.saveGState()
        ctx.addPath(barPath)
        ctx.clip()
        let waveColors = [
            CGColor(red: 0.40, green: 0.96, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.92, green: 0.97, blue: 1.0, alpha: 1.0),
            CGColor(red: 0.58, green: 0.56, blue: 1.0, alpha: 1.0),
        ] as CFArray
        if let waveGrad = CGGradient(colorsSpace: colorSpace, colors: waveColors, locations: [0.0, 0.48, 1.0]) {
            ctx.drawLinearGradient(
                waveGrad,
                start: CGPoint(x: barRect.midX, y: barRect.maxY),
                end: CGPoint(x: barRect.midX, y: barRect.minY),
                options: []
            )
        }
        ctx.restoreGState()
    }

    // Crisp rim highlight along squircle border
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.20))
    ctx.setLineWidth(max(1.0, s * 0.011))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func renderDmgBackground() -> CGImage {
    let width = 660
    let height = 420
    let w = CGFloat(width)
    let h = CGFloat(height)
    let ctx = makeBitmapContext(width: width, height: height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Background slate-indigo gradient
    let bgColors = [
        CGColor(red: 0.06, green: 0.08, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.10, green: 0.13, blue: 0.26, alpha: 1.0),
        CGColor(red: 0.07, green: 0.15, blue: 0.25, alpha: 1.0),
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: 0, y: h),
            end: CGPoint(x: w, y: 0),
            options: []
        )
    }

    // Subtle radial highlight in upper center
    let glowColors = [
        CGColor(red: 0.05, green: 0.68, blue: 0.85, alpha: 0.16),
        CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: w * 0.5, y: h * 0.65),
            startRadius: 0,
            endCenter: CGPoint(x: w * 0.5, y: h * 0.65),
            endRadius: 340,
            options: []
        )
    }

    // Subtle drop zone halos (Finder places AcpmRuntime.app left, Applications right)
    for cx in [175.0, 485.0] {
        let cy = 195.0
        let box = CGRect(x: cx - 72, y: cy - 72, width: 144, height: 144)
        let halo = CGPath(roundedRect: box, cornerWidth: 28, cornerHeight: 28, transform: nil)
        ctx.saveGState()
        ctx.addPath(halo)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.04))
        ctx.fillPath()
        ctx.addPath(halo)
        ctx.setStrokeColor(CGColor(red: 0.4, green: 0.85, blue: 1.0, alpha: 0.18))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Clean guiding arrow between the two zones
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0.35, green: 0.86, blue: 0.98, alpha: 0.85))
    ctx.setLineWidth(3.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 278, y: 195))
    ctx.addLine(to: CGPoint(x: 382, y: 195))
    ctx.move(to: CGPoint(x: 368, y: 209))
    ctx.addLine(to: CGPoint(x: 384, y: 195))
    ctx.addLine(to: CGPoint(x: 368, y: 181))
    ctx.strokePath()
    ctx.restoreGState()

    // Draw crisp typography using AppKit NSGraphicsContext (flipped = false matches CG y-up, or use NSGraphicsContext(cgContext:flipped:false))
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .bold),
        .foregroundColor: NSColor(white: 1.0, alpha: 0.94),
        .paragraphStyle: titleStyle,
    ]
    NSString(string: "AcpmRuntime · Apple Silicon 本地推理运行时")
        .draw(in: CGRect(x: 40, y: 344, width: w - 80, height: 34), withAttributes: titleAttrs)

    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(white: 0.85, alpha: 0.78),
        .paragraphStyle: titleStyle,
    ]
    NSString(string: "将左侧 AcpmRuntime.app 拖入右侧 Applications 文件夹即可安装 · 内置开箱即用 CPU VAD")
        .draw(in: CGRect(x: 40, y: 314, width: w - 80, height: 24), withAttributes: subAttrs)

    let footAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor(red: 0.45, green: 0.86, blue: 0.98, alpha: 0.72),
        .paragraphStyle: titleStyle,
    ]
    NSString(string: "mDNS: http://acpm.local:18790  ·  macOS 15+ Apple Silicon")
        .draw(in: CGRect(x: 40, y: 30, width: w - 80, height: 22), withAttributes: footAttrs)

    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

// 1. Build AppIcon.iconset and convert via iconutil
let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("AcpmAppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (filename, px) in iconSizes {
    let img = renderAppIcon(size: px)
    try savePNG(img, to: iconsetURL.appendingPathComponent(filename))
}

let icnsURL = packagingDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil exited with status \(iconutil.terminationStatus)\n", stderr)
    exit(1)
}
print("[generate-app-icon] Generated \(icnsURL.path)")

// 2. Render DMG installer background
let dmgBgURL = packagingDir.appendingPathComponent("dmg-background.png")
try savePNG(renderDmgBackground(), to: dmgBgURL)
print("[generate-app-icon] Generated \(dmgBgURL.path)")
