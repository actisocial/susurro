#!/usr/bin/env swift

// Genera el ícono de Susurro y lo escribe como AppIcon.appiconset.
//
// Se dibuja por código en vez de exportarse de un editor por una razón
// práctica: el ícono tiene que verse bien desde 1024 px hasta 16 px, y a 16 px
// no sobrevive casi ningún detalle. Teniéndolo como código, ajustar el grosor
// de las barras o el radio de las esquinas y volver a generar los diez tamaños
// es una línea de comando, no media hora de exportar a mano.
//
// Uso:  swift Tools/make-icon.swift

import AppKit
import CoreGraphics
import Foundation

// MARK: - Diseño

/// El motivo es la misma onda que muestra el HUD mientras escucha.
///
/// Se eligió por encima de un micrófono —que sería lo obvio— porque un
/// micrófono en la barra de menús ya lo usan el dictado del sistema, Zoom, Meet
/// y media docena más; a 16 px son todos la misma silueta. Una onda con forma de
/// campana es más distinguible y además dice lo que la app hace: escuchar.
///
/// Las barras van decreciendo hacia los bordes, no solo en altura sino también
/// en opacidad. Eso es lo que da la sensación de susurro en vez de grito.
struct IconDesign {
    /// Proporción del lienzo que ocupa la figura. macOS deja aire alrededor del
    /// ícono; sin ese margen se ve más grande que los del resto del Dock.
    static let inset: CGFloat = 0.098
    /// Radio de las esquinas, como fracción del lado de la figura.
    static let cornerRatio: CGFloat = 0.2237

    /// Alturas relativas de las barras, de izquierda a derecha.
    ///
    /// Cinco y no siete: a 16 px —el tamaño del ícono en el Finder y en las
    /// listas de Ajustes del Sistema— cada barra ocupa poco más de un píxel, y
    /// con siete el conjunto se convierte en una mancha gris. Con cinco todavía
    /// se distinguen y la forma de campana se lee.
    static let barHeights: [CGFloat] = [0.38, 0.68, 1.0, 0.68, 0.38]

    /// Ancho y separación como fracción del **lado de la figura**, no del
    /// lienzo. Calcularlos sobre el lienzo completo hacía que la onda midiera
    /// exactamente lo mismo que el cuadrado redondeado y las barras de los
    /// extremos quedaran montadas sobre el borde.
    static let barWidthRatio: CGFloat = 0.090
    static let barGapRatio: CGFloat = 0.055

    /// Violeta profundo arriba, índigo abajo. Contrasta bien tanto sobre
    /// fondos claros como oscuros y no se confunde con ninguna app del sistema.
    static let topColor = CGColor(red: 0.42, green: 0.31, blue: 0.86, alpha: 1)
    static let bottomColor = CGColor(red: 0.24, green: 0.18, blue: 0.62, alpha: 1)
}

// MARK: - Dibujo

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)

    // --- Figura de fondo ---
    let inset = IconDesign.inset * scale
    let side = scale - inset * 2
    let rect = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * IconDesign.cornerRatio

    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [IconDesign.topColor, IconDesign.bottomColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )

    // Un realce muy sutil arriba: le da volumen sin caer en el brillo plástico
    // de los íconos de hace quince años.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY),
        options: []
    )
    context.restoreGState()

    // --- Onda ---
    let barWidth = IconDesign.barWidthRatio * side
    let gap = IconDesign.barGapRatio * side
    let count = CGFloat(IconDesign.barHeights.count)
    let totalWidth = count * barWidth + (count - 1) * gap
    var x = rect.minX + (side - totalWidth) / 2
    let maxBarHeight = side * 0.54

    for (index, factor) in IconDesign.barHeights.enumerated() {
        let height = maxBarHeight * factor
        let bar = CGRect(
            x: x,
            y: rect.midY - height / 2,
            width: barWidth,
            height: height
        )

        // Las de los extremos se desvanecen: es lo que hace que se lea como un
        // susurro y no como un ecualizador.
        let distance = abs(CGFloat(index) - (count - 1) / 2) / ((count - 1) / 2)
        let alpha = 1.0 - distance * 0.45

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        context.addPath(CGPath(
            roundedRect: bar,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil))
        context.fillPath()

        x += barWidth + gap
    }

    return context.makeImage()
}

// MARK: - Salida

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Susurro/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Los diez archivos que macOS espera, con el nombre exacto de cada uno.
let variants: [(name: String, size: CGFloat, idiom: String, scale: String, point: String)] = [
    ("icon_16x16.png", 16, "mac", "1x", "16x16"),
    ("icon_16x16@2x.png", 32, "mac", "2x", "16x16"),
    ("icon_32x32.png", 32, "mac", "1x", "32x32"),
    ("icon_32x32@2x.png", 64, "mac", "2x", "32x32"),
    ("icon_128x128.png", 128, "mac", "1x", "128x128"),
    ("icon_128x128@2x.png", 256, "mac", "2x", "128x128"),
    ("icon_256x256.png", 256, "mac", "1x", "256x256"),
    ("icon_256x256@2x.png", 512, "mac", "2x", "256x256"),
    ("icon_512x512.png", 512, "mac", "1x", "512x512"),
    ("icon_512x512@2x.png", 1024, "mac", "2x", "512x512"),
]

for variant in variants {
    guard let image = drawIcon(size: variant.size) else {
        FileHandle.standardError.write("no se pudo dibujar \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent(variant.name))
}

// Contents.json: el índice que le dice a Xcode qué archivo corresponde a qué
// tamaño y escala.
let images = variants.map { variant in
    """
        {
          "filename" : "\(variant.name)",
          "idiom" : "\(variant.idiom)",
          "scale" : "\(variant.scale)",
          "size" : "\(variant.point)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("✓ \(variants.count) tamaños en \(iconset.path)")
