//
//  strip-alpha.swift — entfernt den Alphakanal aus einem PNG.
//
//  App Store Connect lehnt Screenshots mit Transparenz ab; `screencapture`
//  liefert aber immer RGBA. Zeichnet das Bild darum verlustfrei auf einen
//  opaken Kontext (noneSkipLast) und schreibt es neu.
//
//  Aufruf:  swift scripts/strip-alpha.swift <ein.png> <aus.png>
//

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("Aufruf: strip-alpha.swift <ein.png> <aus.png>\n".data(using: .utf8)!)
    exit(2)
}

guard let img = NSImage(contentsOfFile: args[1]),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Kann \(args[1]) nicht lesen\n".data(using: .utf8)!)
    exit(1)
}

let w = cg.width, h = cg.height
guard let ctx = CGContext(data: nil, width: w, height: h,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    FileHandle.standardError.write("Kein opaker Kontext möglich\n".data(using: .utf8)!)
    exit(1)
}

// Weiss unterlegen, dann das Bild darüber — falls doch halbtransparente
// Pixel (Fensterecken) im Bild stecken.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

guard let out = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG-Kodierung fehlgeschlagen\n".data(using: .utf8)!)
    exit(1)
}

do {
    try data.write(to: URL(fileURLWithPath: args[2]))
} catch {
    FileHandle.standardError.write("Schreiben fehlgeschlagen: \(error)\n".data(using: .utf8)!)
    exit(1)
}
