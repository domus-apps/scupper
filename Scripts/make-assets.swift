#!/usr/bin/env swift
// Generates the Icon Composer document layers (Assets/AppIcon.icon), a still
// of the icon as macOS renders it (Assets/icon-1024.png), the README banner
// (Assets/banner.png) and the GitHub social preview (Assets/og-image.png)
// programmatically, so the artwork is reproducible from source. The .icns the
// app ships is actool's render of the same document (Scripts/bundle.sh).
// Run: swift Scripts/make-assets.swift
//
// Styled after the Creator Studio icon language (see the Icon section):
// hue-shifting ground, a monochromatic lit-gel glyph built from tube
// outlines and filled panels — a trash can.

import AppKit
import CoreImage
import SwiftUI

// MARK: - Helpers

let ciContext = CIContext()

func makeBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func withContext(_ rep: NSBitmapImageRep, _ draw: (CGContext) -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.current = nil
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rgb = CGColorSpaceCreateDeviceRGB()

func linearGradient(_ cg: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

/// The macOS app-icon silhouette: a continuous-corner rounded rect (straight
/// edges, Apple's smooth corner curve). Radius fitted against the system's
/// live icon mask (214.5px on the 824px shape).
func squircle(in rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * (214.5 / 824), style: .continuous).cgPath
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: ci.extent)
    return ciContext.createCGImage(blurred, from: ci.extent)!
}

// MARK: - Icon (designed in a 1024x1024 space, bottom-left origin)

/* The design context is Apple's Creator Studio icons as refreshed in
   September 2026 (Final Cut Pro, Keynote, Logic Pro, MainStage, Pixelmator
   Pro…), measured by pixel-sampling the installed icons:

     - a squircle whose vertical gradient shifts HUE and darkens: saturated
       key color at the top, a step warmer/cooler and ~10 L deeper at the
       bottom, with a bright hairline along the top edge;
     - two glyph materials, both the key hue only. TUBES: thick rounded
       strokes carrying a linear gradient along their run from a pale tint
       (L 70–85) down to a deep key color that nearly sinks into the ground
       (L 32–38). PANELS: translucent mid tints (alpha ≈0.55) the ground
       shows through, a touch lighter at the top, with a hairline rim;
     - details (stripes, dots) are small panels, low contrast;
     - a small soft shadow under the glyph; no glow, no highlights;
     - filling roughly 60–65% of the width, centered.

   Scupper: a sea-teal ground running from ocean blue down to deep navy,
   and for a glyph an app being cleaned — a translucent app tile with a
   broom sweeping across its lower corner, crumbs flying off the edge.
   Cleaning, and an app, in one picture. */

let designRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824) // standard macOS icon grid

let keyColor: UInt32 = 0x29B6D6
let groundTop: UInt32 = 0x1794B6
let groundMid: UInt32 = 0x0F6C92
let groundBottom: UInt32 = 0x0B3D62
let tubeLight: UInt32 = 0xE4F8FF     // the pale end of a tube
let tubeDeep: UInt32 = 0x2C9CBC      // the end that sinks toward the ground
let panelTint: UInt32 = 0x5FCBE8     // translucent panel body
let panelTop: UInt32 = 0xBEEEFB      // the lighter top of a panel
let dropTint: UInt32 = 0xD6F4FC      // the droplets, lighter panels
let shadowTint: UInt32 = 0x032033

/// Ground: squircle, ocean→navy gradient (hue shifting cooler, darkening
/// toward the bottom), a hairline of light along the top edge, and the
/// icon's outer shadow.
func drawIconBackground(_ cg: CGContext) {
    let shape = squircle(in: bgRect)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.28))
    cg.addPath(shape)
    cg.setFillColor(color(keyColor))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let grad = CGGradient(
        colorsSpace: rgb,
        colors: [color(groundTop), color(groundMid), color(groundBottom)] as CFArray,
        locations: [0, 0.55, 1])!
    cg.drawLinearGradient(
        grad, start: CGPoint(x: 512, y: bgRect.maxY), end: CGPoint(x: 512, y: bgRect.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // The top edge catches the light: bright, and gone within a few pixels
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.maxY - 14))
    cg.restoreGState()
}

// MARK: Glyph geometry

/* The glyph: an app tile (a rounded square, translucent) sitting up and to
   the left, and a broom coming in from the top right — its handle a tube,
   its head a tilted panel — sweeping the tile's lower corner, with three
   crumbs being swept off to the lower left. What the app does: clean an
   app out, leftovers included. */
let tileRect = CGRect(x: 236, y: 470, width: 336, height: 336)
let tileRadius: CGFloat = 84
let handleTop = CGPoint(x: 764, y: 790)
let handleBottom = CGPoint(x: 508, y: 480)       // where the ferrule sits
let handleWidth: CGFloat = 60
/// The broom head: a rounded trapezoid set across the handle's end, wider
/// at the bristle tips than where the handle enters.
let headCenter = CGPoint(x: 444, y: 404)
let headNear: CGFloat = 214      // across, at the handle side
let headFar: CGFloat = 286       // across, at the bristle tips
let headAlong: CGFloat = 158     // along the handle
let headCorner: CGFloat = 46
/// The ferrule: a short band across the handle where it enters the head.
let ferruleAcross: CGFloat = 104
let ferruleAlong: CGFloat = 36
let crumbs: [(center: CGPoint, radius: CGFloat)] = [
    (CGPoint(x: 336, y: 292), 22),
    (CGPoint(x: 284, y: 240), 14),
    (CGPoint(x: 268, y: 334), 12),
]

var handleAngle: CGFloat {
    atan2(handleBottom.y - handleTop.y, handleBottom.x - handleTop.x)
}
/// Unit vectors along the handle (toward the bristle tips) and across it.
var along: CGPoint { CGPoint(x: cos(handleAngle), y: sin(handleAngle)) }
var across: CGPoint { CGPoint(x: -along.y, y: along.x) }

func handleCenterline() -> CGPath {
    let path = CGMutablePath()
    path.move(to: handleTop)
    path.addLine(to: handleBottom)
    return path
}

func stroked(_ centerline: CGPath, width: CGFloat) -> CGPath {
    centerline.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func tile() -> CGPath {
    CGPath(roundedRect: tileRect, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
}

/// A transform from head-local coordinates (x across the handle, y along
/// it toward the tips) into the design space.
func headTransform() -> CGAffineTransform {
    CGAffineTransform(translationX: headCenter.x, y: headCenter.y)
        .rotated(by: handleAngle - .pi / 2)
}

/// The head: a rounded trapezoid, narrow where the handle enters (local
/// -y) and wide at the bristle tips (local +y).
func head(scale: CGFloat = 1) -> CGPath {
    let near = headNear * scale / 2, far = headFar * scale / 2, half = headAlong * scale / 2
    let r = headCorner * scale
    let corners = [
        CGPoint(x: -near, y: -half), CGPoint(x: near, y: -half),
        CGPoint(x: far, y: half), CGPoint(x: -far, y: half),
    ]
    let t = headTransform()
    let path = CGMutablePath()
    // Start on the middle of the near edge so every corner is an arc join
    path.move(to: CGPoint(x: 0, y: -half), transform: t)
    for i in 1...4 {
        let p = corners[i % 4], q = corners[(i + 1) % 4]
        path.addArc(tangent1End: p, tangent2End: q, radius: r, transform: t)
    }
    path.closeSubpath()
    return path
}

/// Bristle lines: thin strokes along the handle's direction, spread across
/// the head and running out to the tips, so the block reads as a broom.
func bristles(scale: CGFloat = 1) -> CGPath {
    let path = CGMutablePath()
    let t = headTransform()
    let half = headAlong * scale / 2
    for i in -2...2 {
        let x = CGFloat(i) * headFar * scale * 0.16
        path.move(to: CGPoint(x: x * 0.85, y: -half * 0.15), transform: t)
        path.addLine(to: CGPoint(x: x, y: half * 0.78), transform: t)
    }
    return path.copy(strokingWithWidth: 9 * scale, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func ferrule(scale: CGFloat = 1) -> CGPath {
    var t = CGAffineTransform(translationX: handleBottom.x, y: handleBottom.y)
        .rotated(by: handleAngle - .pi / 2)
    let w = ferruleAcross * scale, h = ferruleAlong * scale
    return CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                  cornerWidth: h / 2, cornerHeight: h / 2, transform: &t)
}

func crumb(_ c: (center: CGPoint, radius: CGFloat), scale: CGFloat = 1) -> CGPath {
    let r = c.radius * scale
    return CGPath(ellipseIn: CGRect(x: c.center.x - r, y: c.center.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

// MARK: Glyph materials

/// The soft drop shadow every glyph piece casts onto the ground.
func dropShadow(_ cg: CGContext, _ shape: CGPath, alpha: CGFloat) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(shadowTint, alpha))
    cg.addPath(shape)
    cg.setFillColor(color(shadowTint, 0.001))
    cg.fillPath()
    cg.restoreGState()
}

/// A hairline rim along the top of a shape, fading out downward. The shape
/// is a stroker outline in the tube case and must be normalized first (its
/// inner corners hide self-intersecting loops that a stroke would trace).
func rim(_ cg: CGContext, _ shape: CGPath, width: CGFloat, alpha: CGFloat) {
    let bounds = shape.boundingBox
    let ring = shape.normalized(using: .winding)
        .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    linearGradient(
        cg, in: ring,
        colors: [color(0xFFFFFF, alpha), color(0xFFFFFF, 0.04)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY))
}

/* TUBE: a rounded stroke whose color runs, along the gradient axis given,
   from a pale tint to a deep key color that all but sinks into the ground —
   the refreshed icons light one end of every stroke and let the other end
   fall into shadow. Pale for most of the run. */
func drawTube(_ cg: CGContext, shape: CGPath, from lightEnd: CGPoint, to deepEnd: CGPoint) {
    dropShadow(cg, shape, alpha: 0.4)
    linearGradient(
        cg, in: shape,
        colors: [color(tubeLight), color(tubeLight), color(tubeDeep)],
        from: lightEnd, to: deepEnd)
    rim(cg, shape, width: 2.5, alpha: 0.45)
}

/* PANEL: a translucent slab of the key hue the ground (and anything drawn
   before it) shows through, a little lighter at its top, with a hairline
   rim. `tint` is the body color, `alpha` how much shows through. */
func drawPanel(_ cg: CGContext, shape: CGPath, tint: UInt32, alpha: CGFloat, shadow: Bool) {
    let bounds = shape.boundingBox
    if shadow { dropShadow(cg, shape, alpha: 0.32) }
    linearGradient(
        cg, in: shape,
        colors: [color(panelTop, alpha), color(tint, alpha)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY))
    rim(cg, shape, width: 2, alpha: 0.35)
}

func drawGlyph(_ cg: CGContext, scale: CGFloat, boost: Bool) {
    let width = boost ? handleWidth * 1.2 : handleWidth
    let small: CGFloat = boost ? 1.15 : 1

    // The app tile: glass, the ground showing through
    drawPanel(cg, shape: tile(), tint: panelTint, alpha: 0.46, shadow: true)
    // Crumbs already swept off its corner
    for c in crumbs {
        drawPanel(cg, shape: crumb(c, scale: small), tint: dropTint, alpha: 0.78, shadow: true)
    }
    // The broom: head over the tile's corner, then bristles, handle, ferrule
    drawPanel(cg, shape: head(scale: small), tint: dropTint, alpha: 0.88, shadow: true)
    cg.saveGState()
    cg.addPath(head(scale: small))
    cg.clip()
    cg.addPath(bristles(scale: small))
    cg.setFillColor(color(groundMid, 0.3))
    cg.fillPath()
    cg.restoreGState()
    drawTube(cg, shape: stroked(handleCenterline(), width: width),
             from: handleTop, to: CGPoint(x: 560, y: 540))
    drawPanel(cg, shape: ferrule(scale: small), tint: tubeDeep, alpha: 0.9, shadow: false)
}

/// Renders the complete icon at `px` and returns the bitmap.
func makeIcon(px: Int) -> NSBitmapImageRep {
    let scale = CGFloat(px) / 1024
    // Small sizes: a thicker tube and a slightly larger glyph keep it
    // legible in the Dock, like the small-size variants of system icons.
    let boost = px <= 64
    let shape = squircle(in: bgRect)

    let rep = makeBitmap(px, px)
    withContext(rep) { cg in
        cg.scaleBy(x: scale, y: scale)
        drawIconBackground(cg)
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        if boost {
            cg.translateBy(x: 512, y: 512)
            cg.scaleBy(x: 1.1, y: 1.1)
            cg.translateBy(x: -512, y: -512)
        }
        drawGlyph(cg, scale: scale, boost: boost)
        cg.restoreGState()
    }
    return rep
}

// MARK: - Icon Composer layer (macOS 26+ .icon document)

/* In a .icon document the 1024pt canvas IS the icon shape — the system adds
   its own margins — whereas our design space puts the squircle at 100..924,
   so the glyph is remapped to land at the same visual position. The layer
   is the flat glyph in its light tint; the system renders the glass. */
func makeIconLayer(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeBitmap(1024, 1024)
    withContext(rep) { cg in
        cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
        cg.translateBy(x: -100, y: -100)
        draw(cg)
    }
    return rep
}

/* Icon Composer layers. macOS 26 renders the .icon document, not the PNG
   above, so the two materials have to be authored as separate layers the
   system can light: each PNG carries its own coloring (the tube's run from
   pale to deep, the panel tints), and the document gives the tile group
   translucency + blur (glass the ground shows through) and every group a
   soft shadow and specular. Draw order is the document's group order (see
   iconGroups below). */
func layerTile(_ cg: CGContext) {
    linearGradient(cg, in: tile(), colors: [color(panelTop), color(panelTint)],
                   from: CGPoint(x: tileRect.midX, y: tileRect.maxY), to: CGPoint(x: tileRect.midX, y: tileRect.minY))
}
func layerCrumbs(_ cg: CGContext) {
    cg.setFillColor(color(dropTint))
    for c in crumbs { cg.addPath(crumb(c)) }
    cg.fillPath()
}
func layerHead(_ cg: CGContext) {
    cg.setFillColor(color(dropTint))
    cg.addPath(head())
    cg.fillPath()
    cg.saveGState()
    cg.addPath(head())
    cg.clip()
    cg.addPath(bristles())
    cg.setFillColor(color(groundMid, 0.3))
    cg.fillPath()
    cg.restoreGState()
}
func layerHandle(_ cg: CGContext) {
    linearGradient(cg, in: stroked(handleCenterline(), width: handleWidth),
                   colors: [color(tubeLight), color(tubeLight), color(tubeDeep)],
                   from: handleTop, to: CGPoint(x: 560, y: 540))
    cg.setFillColor(color(tubeDeep))
    cg.addPath(ferrule())
    cg.fillPath()
}

/// One flat silhouette of everything, for the README's small inline uses.
func drawFlatGlyph(_ cg: CGContext) {
    cg.setFillColor(color(tubeLight))
    cg.addPath(tile())
    for c in crumbs { cg.addPath(crumb(c)) }
    cg.addPath(head())
    cg.addPath(stroked(handleCenterline(), width: handleWidth))
    cg.fillPath()
}

// MARK: - Shared banner elements

func sparklePath(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = CGPoint(x: center.x, y: center.y + radius)
    let e = CGPoint(x: center.x + radius, y: center.y)
    let s = CGPoint(x: center.x, y: center.y - radius)
    let w = CGPoint(x: center.x - radius, y: center.y)
    path.move(to: n)
    path.addQuadCurve(to: e, control: center)
    path.addQuadCurve(to: s, control: center)
    path.addQuadCurve(to: w, control: center)
    path.addQuadCurve(to: n, control: center)
    path.closeSubpath()
    return path
}

func drawSparkles(_ cg: CGContext, _ sparkles: [(x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)]) {
    for s in sparkles {
        cg.addPath(sparklePath(center: CGPoint(x: s.x, y: s.y), radius: s.r))
        cg.setFillColor(color(0xFFFFFF, s.a))
        cg.fillPath()
    }
}

/* Banner palette: deep tints of the key color for the ground, pale tints
   of it for the tagline and pill labels. */
let bannerTop: UInt32 = 0x0B3547
let socialTop: UInt32 = 0x0E3F55
let bannerBottom: UInt32 = 0x04161F
let pillLabelColor = NSColor(srgbRed: 0.80, green: 0.93, blue: 0.97, alpha: 1)
let taglineColor = NSColor(srgbRed: 0.72, green: 0.90, blue: 0.96, alpha: 1)
let tagline = "Delete an app and everything it left behind"

func pillText(_ label: String, fontSize: CGFloat) -> NSAttributedString {
    NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: pillLabelColor,
    ])
}

func pillWidth(label: String, fontSize: CGFloat, pad: CGFloat) -> CGFloat {
    pad + pillText(label, fontSize: fontSize).size().width + pad
}

@discardableResult
func drawPill(
    _ cg: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, label: String,
    fontSize: CGFloat, pad: CGFloat
) -> CGFloat {
    let text = pillText(label, fontSize: fontSize)
    let pill = CGRect(
        x: x, y: y, width: pillWidth(label: label, fontSize: fontSize, pad: pad), height: height)

    cg.addPath(CGPath(roundedRect: pill, cornerWidth: height / 4, cornerHeight: height / 4, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.07))
    cg.fillPath()
    cg.addPath(CGPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), cornerWidth: height / 4 - 1, cornerHeight: height / 4 - 1, transform: nil))
    cg.setStrokeColor(color(0xFFFFFF, 0.14))
    cg.setLineWidth(2.5)
    cg.strokePath()

    text.draw(at: NSPoint(
        x: pill.minX + pad, y: pill.minY + (pill.height - text.size().height) / 2))
    return pill.maxX
}

let pillLabels = ["Drop an app in", "See what's left", "One click to the Trash"]

// MARK: - Banner (1800 x 600)

func drawBanner(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1800, height: 600)
    let frame = CGPath(roundedRect: canvas, cornerWidth: 40, cornerHeight: 40, transform: nil)
    /* The family rule: each banner is a deep tint of the app's own key
       color (Louver 1C300E, Keystone 30130A) — here the sea teal, darkened. */
    linearGradient(
        cg, in: frame,
        colors: [color(bannerTop), color(bannerBottom)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    cg.saveGState()
    cg.addPath(frame)
    cg.clip()
    drawSparkles(cg, [
        (1420, 470, 26, 0.07), (1580, 320, 40, 0.06), (1710, 480, 18, 0.06),
        (1500, 130, 22, 0.05), (1680, 190, 30, 0.07), (1350, 250, 14, 0.05),
    ])
    cg.restoreGState()

    cg.draw(icon, in: CGRect(x: 100, y: 118, width: 364, height: 364))

    let title = NSAttributedString(string: "Scupper", attributes: [
        .font: NSFont.systemFont(ofSize: 130, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 520, y: 300))

    let taglineText = NSAttributedString(string: tagline, attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: taglineColor,
    ])
    taglineText.draw(at: NSPoint(x: 528, y: 218))

    var x: CGFloat = 528
    for label in pillLabels {
        x = drawPill(cg, x: x, y: 108, height: 72, label: label, fontSize: 36, pad: 28) + 22
    }
}

// MARK: - GitHub social preview (1280 x 640)

func drawSocialPreview(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1280, height: 640)
    linearGradient(
        cg, in: CGPath(rect: canvas, transform: nil),
        colors: [color(socialTop), color(bannerBottom)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    drawSparkles(cg, [
        (90, 560, 26, 0.06), (230, 620, 16, 0.05), (170, 480, 12, 0.05),
        (1160, 120, 30, 0.06), (1060, 40, 18, 0.05), (1230, 260, 14, 0.05),
    ])

    func drawCentered(_ text: NSAttributedString, y: CGFloat) {
        text.draw(at: NSPoint(x: canvas.midX - text.size().width / 2, y: y))
    }

    cg.draw(icon, in: CGRect(x: canvas.midX - 125, y: 355, width: 250, height: 250))

    drawCentered(
        NSAttributedString(string: "Scupper", attributes: [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white,
        ]), y: 238)

    drawCentered(
        NSAttributedString(string: tagline, attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .medium),
            .foregroundColor: taglineColor,
        ]), y: 176)

    let gap: CGFloat = 16
    let widths = pillLabels.map { pillWidth(label: $0, fontSize: 30, pad: 24) }
    var x = canvas.midX - (widths.reduce(0, +) + gap * CGFloat(pillLabels.count - 1)) / 2
    for (label, width) in zip(pillLabels, widths) {
        drawPill(cg, x: x, y: 82, height: 62, label: label, fontSize: 30, pad: 24)
        x += width + gap
    }
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: "Assets/AppIcon.icon/Assets", withIntermediateDirectories: true)
for stale in (try? fm.contentsOfDirectory(atPath: "Assets/AppIcon.icon/Assets")) ?? [] {
    try? fm.removeItem(atPath: "Assets/AppIcon.icon/Assets/\(stale)")
}

/* The document's groups, listed TOP first the way Icon Composer shows them
   (checked by compiling a two-layer test document: the first group covers
   the second). Each group: its layer PNG, and the material the system adds. */
struct IconGroup {
    let name: String
    let draw: (CGContext) -> Void
    let glass: Bool          // translucent, blurred — the ground shows through
}
let iconGroups: [IconGroup] = [
    IconGroup(name: "handle", draw: layerHandle, glass: false),
    IconGroup(name: "head", draw: layerHead, glass: false),
    IconGroup(name: "crumbs", draw: layerCrumbs, glass: false),
    IconGroup(name: "tile", draw: layerTile, glass: true),
]
for group in iconGroups {
    savePNG(makeIconLayer(group.draw), "Assets/AppIcon.icon/Assets/\(group.name).png")
}

func srgbComponents(_ hex: UInt32) -> String {
    let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
    return String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", r, g, b)
}
func groupJSON(_ group: IconGroup) -> String {
    var props = """
          "layers": [
            {
              "glass": true,
              "image-name": "\(group.name).png",
              "name": "\(group.name)"
            }
          ],
          "shadow": {
            "kind": "neutral",
            "opacity": 0.5
          },
          "specular": true
    """
    if group.glass {
        props += """
        ,
          "translucency": {
            "enabled": true,
            "value": 0.5
          },
          "blur-material": 0.5
        """
    }
    return "    {\n" + props + "\n    }"
}
/* The background is the same two-stop gradient the rendered icon uses (a
   2-stop linear-gradient is what the format takes; see CLAUDE.md). */
let iconDocument = """
{
  "fill": {
    "linear-gradient": [
      "\(srgbComponents(groundTop))",
      "\(srgbComponents(groundBottom))"
    ]
  },
  "groups": [
\(iconGroups.map(groupJSON).joined(separator: ",\n"))
  ],
  "supported-platforms": {
    "circles": [
      "watchOS"
    ],
    "squares": "shared"
  }
}

"""
try! iconDocument.write(toFile: "Assets/AppIcon.icon/icon.json", atomically: true, encoding: .utf8)
print("wrote Assets/AppIcon.icon/icon.json (\(iconGroups.count) groups)")

/* The banner, the social preview, and icon-1024.png show the icon as macOS
   renders it — the compiled Icon Composer document with the Liquid Glass
   treatment — rather than the PNG drawn above, so they match the Dock,
   Finder, and the website (which renders its icons the same way). The document is compiled with
   actool into a throwaway stub bundle, unique per run so Launch Services
   never hands back a cached icon of another app. Every requested size is
   drawn while the stub still exists; nil (fall back to the PNG render) if
   actool is unavailable. The .icns the app ships is actool's own render of
   the same document (Scripts/bundle.sh), so none is generated here. */
func systemRenderedIcon(sizes: [Int]) -> [Int: NSBitmapImageRep]? {
    let fm = FileManager.default
    let slug = URL(fileURLWithPath: fm.currentDirectoryPath).lastPathComponent
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("domus-icon-\(slug)-\(ProcessInfo.processInfo.processIdentifier)")
    defer { try? fm.removeItem(at: root) }
    let compiled = root.appendingPathComponent("compiled")
    let stub = root.appendingPathComponent("\(slug)-icon-preview.app")
    let resources = stub.appendingPathComponent("Contents/Resources")
    let executables = stub.appendingPathComponent("Contents/MacOS")
    for dir in [compiled, resources, executables] {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let actool = Process()
    actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    actool.arguments = [
        "actool", fm.currentDirectoryPath + "/Assets/AppIcon.icon",  // absolute: ibtoold caches by path
        "--compile", compiled.path, "--app-icon", "AppIcon",
        "--output-partial-info-plist", compiled.appendingPathComponent("partial.plist").path,
        "--platform", "macosx", "--minimum-deployment-target", "26.0",
        "--enable-on-demand-resources", "NO",
    ]
    actool.standardOutput = FileHandle.nullDevice
    actool.standardError = FileHandle.nullDevice
    guard (try? actool.run()) != nil else { return nil }
    actool.waitUntilExit()
    guard actool.terminationStatus == 0,
          (try? fm.copyItem(at: compiled.appendingPathComponent("Assets.car"),
                            to: resources.appendingPathComponent("Assets.car"))) != nil
    else { return nil }
    try? fm.copyItem(at: compiled.appendingPathComponent("AppIcon.icns"),
                     to: resources.appendingPathComponent("AppIcon.icns"))

    let info: [String: Any] = [
        "CFBundleIdentifier": "com.jhaemin.\(slug).icon-preview", "CFBundleName": slug,
        "CFBundlePackageType": "APPL", "CFBundleExecutable": "stub",
        "CFBundleIconName": "AppIcon", "CFBundleIconFile": "AppIcon",
    ]
    let stubExecutable = executables.appendingPathComponent("stub")
    guard let plist = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
          (try? plist.write(to: stub.appendingPathComponent("Contents/Info.plist"))) != nil,
          (try? "#!/bin/sh\n".write(to: stubExecutable, atomically: true, encoding: .utf8)) != nil
    else { return nil }
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubExecutable.path)

    let icon = NSWorkspace.shared.icon(forFile: stub.path)
    var rendered: [Int: NSBitmapImageRep] = [:]
    for px in sizes {
        let rep = makeBitmap(px, px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        rendered[px] = rep
    }
    return rendered
}

/* Rendered by macOS from the document just written (see systemRenderedIcon);
   the PNG render is only the fallback. icon-1024.png is the repo's one
   canonical still of the icon. */
let systemIcon = systemRenderedIcon(sizes: [1024, 728])
savePNG(systemIcon?[1024] ?? makeIcon(px: 1024), "Assets/icon-1024.png")
let bannerIcon = (systemIcon?[728] ?? makeIcon(px: 728)).cgImage!
let banner = makeBitmap(1800, 600)
withContext(banner) { drawBanner($0, icon: bannerIcon) }
savePNG(banner, "Assets/banner.png")

let og = makeBitmap(1280, 640)
withContext(og) { cg in
    drawSocialPreview(cg, icon: bannerIcon)
}
savePNG(og, "Assets/og-image.png")
