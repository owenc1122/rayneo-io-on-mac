// 截图文字识别（macOS Vision，本机，不上传）：ocr <png> [x y w h]  → 每行「y\t文字」，从上到下
import Foundation
import Vision
import AppKit
let a = CommandLine.arguments
guard a.count >= 2, let img = NSImage(contentsOfFile: a[1]),
      var cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(2) }
if a.count >= 6, let x = Int(a[2]), let y = Int(a[3]), let w = Int(a[4]), let h = Int(a[5]),
   let c = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) { cg = c }
// 放大 3 倍再识别（眼镜画面字小）
let W = cg.width * 3, H = cg.height * 3
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
let big = ctx.makeImage()!
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.recognitionLanguages = ["zh-Hans", "en-US"]
req.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: big, options: [:]).perform([req])
let obs = (req.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
for o in obs {
    let y = Int((1 - o.boundingBox.midY) * Double(cg.height))
    let x = Int(o.boundingBox.minX * Double(cg.width))
    print("\(y)\t\(x)\t\(o.topCandidates(1).first?.string ?? "")")
}
