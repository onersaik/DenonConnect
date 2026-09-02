import AppKit

let srcPNG = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/icon_1024.png"
let outPNG = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/icon_test_1024.png"

guard let src = NSImage(contentsOfFile: srcPNG),
      let tiff = src.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fputs("No se pudo leer \(srcPNG)\n", stderr)
    exit(1)
}

let size = NSSize(width: 1024, height: 1024)
let out = NSImage(size: size)
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
src.draw(in: NSRect(origin: .zero, size: size),
         from: NSRect(origin: .zero, size: src.size),
         operation: .copy,
         fraction: 1)

// Cinta TEST (cian) en la esquina inferior
let banner = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 168),
                          xRadius: 28, yRadius: 28)
NSColor(calibratedRed: 0.08, green: 0.78, blue: 0.92, alpha: 0.94).setFill()
banner.fill()

let para = NSMutableParagraphStyle()
para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 118, weight: .heavy),
    .foregroundColor: NSColor.black,
    .paragraphStyle: para,
    .kern: 8
]
let text = NSString(string: "TEST")
text.draw(in: NSRect(x: 70, y: 88, width: 884, height: 140), withAttributes: attrs)
out.unlockFocus()

guard let tiffOut = out.tiffRepresentation,
      let pngRep = NSBitmapImageRep(data: tiffOut),
      let png = pngRep.representation(using: .png, properties: [:]) else {
    fputs("No se pudo escribir PNG\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPNG))
print("TEST icon PNG: \(outPNG)")
