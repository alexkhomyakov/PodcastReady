import AppKit
import CoreGraphics
import Foundation
import Vision

/// Targets measured off the real rig on 2026-09-06/07 rather than taken from
/// general advice. Every one of these came from a frame we actually shot:
/// see `docs/tuning-targets.md` for the readings behind them.
enum MetricTarget {
    /// Forehead luma. 128 read as underexposed on camera; 164 at 55% Elgato
    /// looked right. Below ~150 the face stops being the brightest thing.
    /// How bright the face should be — the LOOK, not a correctness threshold.
    ///
    /// 165 is a conventionally well-exposed broadcast portrait. It is not the
    /// only right answer: a deliberate low-key portrait sits around 115-130,
    /// falls off sooner, and reads calmer and more filmic. This band was fixed
    /// at 155-185 for a day and flagged a frame the author preferred as
    /// underexposed — which is a target arguing with its owner, the same way
    /// white balance did before `warmthTarget` existed.
    static var foreheadTarget: Double {
        UserDefaults.standard.object(forKey: "PodcastReady.foreheadTarget") as? Double ?? 165
    }

    /// Tolerance around it. Kept at +/-15 whatever the target, so a low-key look
    /// is held as tightly as a bright one.
    static var forehead: ClosedRange<Double> {
        (foreheadTarget - 15)...(foreheadTarget + 15)
    }

    /// Lit cheek over shadow cheek. On-axis ring light gave 1.0:1 (flat, no
    /// modelling). Off-axis with no fill gave 10:1 (shadow side at luma 13).
    static let keyFill: ClosedRange<Double> = 1.5...2.8

    /// Forehead minus the wall beside the head. Daylight with shutters open
    /// gave -23 (background brighter than the face); shutters closed gave +70.
    static let faceOverWallMin: Double = 70

    /// A neutral top or wall should come back near zero R-B. The white shirt
    /// under a 3000K-locked WB in daylight read -37; with shutters down, +3.
    static let neutralRB: Double = 20

    /// Magic Fix corrects to a tighter bar than the one used to decide whether
    /// something is WRONG. +/-20 is genuinely fine to look at, so the metric row
    /// stays green there — but if the loop is already touching white balance it
    /// may as well land properly rather than stop at "acceptable".
    static let neutralRBAutoCorrect: Double = 12

    /// How warm the picture should RENDER, as a percentage of the reference
    /// patch's own brightness — NOT as a raw R-B difference.
    ///
    /// Relative because R-B is a difference and colour is a ratio. Measured on
    /// this rig: a frame that looked natural had top R-B +8.9 at luma 104
    /// (8.6%); after the room was darkened, R-B +15.3 at luma 58 is 26.5% — a
    /// three-fold jump in saturation while the absolute number barely moved and
    /// the target reported everything in range. Lowering face brightness
    /// silently made the same warmth setting far heavier.
    static var warmthPercent: Double {
        UserDefaults.standard.object(forKey: "PodcastReady.warmthPercent") as? Double ?? 8
    }

    /// The absolute R-B to aim for on a patch of this brightness.
    static func warmthAim(level: Double) -> Double {
        warmthPercent / 100 * max(level, 1)
    }

    /// Tolerances, also as a share of level, for the same reason. +/-20 absolute
    /// was a fifth of the level in a bright frame and a third in a dark one.
    static let tolerancePercent: Double = 6          // shown as a fault beyond this
    static let autoCorrectTolerancePercent: Double = 4   // Magic Fix corrects beyond this

    static func tolerance(level: Double, percent: Double) -> Double {
        percent / 100 * max(level, 1)
    }

    static let clipPctMax: Double = 0.5

    /// Shutters closed with no fill crushed 16% of the frame to pure black.
    static let crushPctMax: Double = 5.0
}

struct Metric: Identifiable {
    enum Status { case good, warn, info }

    let id = UUID()
    let label: String
    let value: String
    let target: String
    let status: Status
}

struct FrameMetrics {
    let faceFound: Bool

    // Face samples (nil when no face was detected)
    let forehead: Double?
    let cheekKey: Double?
    let cheekFill: Double?
    /// Frame-relative, so they can name a direction to move the light in.
    /// "Key : fill" is max/min and deliberately says nothing about which side
    /// the light is on — which is useless advice when the ratio is 1.0 and you
    /// cannot see the asymmetry to judge it yourself.
    let cheekLeft: Double?
    let cheekRight: Double?
    let shirt: Double?
    let wall: Double?
    let shirtRB: Double?
    let wallRB: Double?

    /// Focus quality, measured across the eyes only.
    ///
    /// Whole-frame sharpness is the wrong signal and is exactly why camera
    /// autofocus grabs the microphone: the room behind has far more
    /// high-frequency detail than a face, so the frame-wide peak is not the
    /// peak for the subject. Cheeks are smooth enough to dilute it too, so this
    /// is a band across the eyes — the finest detail a face has.
    ///
    /// Normalised by mean luma squared so it is comparable between frames of
    /// different brightness.
    let eyeSharpness: Double?

    // Whole-frame — always available, no face detection needed
    let meanLuma: Double
    let clipPct: Double
    let crushPct: Double

    /// Which side of the FRAME the key is currently favouring, if either.
    var keySide: String? {
        guard let l = cheekLeft, let r = cheekRight, max(l, r) > 1 else { return nil }
        let ratio = max(l, r) / min(l, r)
        if ratio < 1.04 { return nil }              // genuinely flat: no direction to give
        return l > r ? "camera-left" : "camera-right"
    }

    var keyFillRatio: Double? {
        guard let k = cheekKey, let f = cheekFill, f > 1 else { return nil }
        return k / f
    }

    var faceOverWall: Double? {
        guard let f = forehead, let w = wall else { return nil }
        return f - w
    }

    var shirtOverFace: Double? {
        guard let s = shirt, let f = forehead else { return nil }
        return s - f
    }
}

// MARK: - Rows for display

extension FrameMetrics {
    var rows: [Metric] {
        var out: [Metric] = []

        if let v = forehead {
            out.append(Metric(
                label: "Forehead",
                value: String(format: "%.0f", v),
                target: String(format: "%.0f–%.0f", MetricTarget.forehead.lowerBound, MetricTarget.forehead.upperBound),
                status: MetricTarget.forehead.contains(v) ? .good : .warn))
        }

        if let r = keyFillRatio {
            var target = "1.5–2.8:1"
            if let l = cheekLeft, let rr = cheekRight {
                target += String(format: "   L %.0f / R %.0f", l, rr)
            }
            out.append(Metric(
                label: "Key : fill",
                value: String(format: "%.1f:1", r),
                target: target,
                status: MetricTarget.keyFill.contains(r) ? .good : .warn))
        }

        if let d = faceOverWall {
            out.append(Metric(
                label: "Face − wall",
                value: String(format: "%+.0f", d),
                target: "≥ +70",
                status: d >= MetricTarget.faceOverWallMin ? .good : .warn))
        }

        if let d = shirtOverFace {
            out.append(Metric(
                label: "Shirt − face",
                value: String(format: "%+.0f", d),
                target: "negative",
                status: d < 0 ? .good : .warn))
        }

        // Two independent neutral references. A coloured top invalidates the
        // first and a warmly-lit wall the second, so only flag when both drift.
        if let s = shirtRB {
            let level = shirt ?? 0
            let aim = MetricTarget.warmthAim(level: level)
            let tol = MetricTarget.tolerance(level: level, percent: MetricTarget.tolerancePercent)
            // Shown as a share of level, because that is what the eye reads.
            let pct = level > 1 ? s / level * 100 : 0
            out.append(Metric(
                label: "Top R−B",
                value: String(format: "%+.0f  (%.0f%%)", s, pct),
                target: String(format: "%.0f%% ±%.0f%% warm", MetricTarget.warmthPercent, MetricTarget.tolerancePercent),
                status: abs(s - aim) <= tol ? .good : .warn))
        }
        if let w = wallRB {
            // When the top gives a trustworthy neutral reading, a coloured wall
            // is a decision rather than a fault — RGB background lighting is a
            // normal thing to want, and flagging it forever is how a warning
            // stops being read.
            // Measure the reference against the WARMTH TARGET, not against zero.
            // Once a warm look is chosen the top sits at +20 or so by design,
            // and comparing it to zero declares the only good reference in the
            // frame untrustworthy — which starts grading a deliberately blue
            // wall as a colour fault again.
            let level = shirt ?? 0
            let haveGoodReference = (shirtRB.map {
                abs($0 - MetricTarget.warmthAim(level: level))
                    <= MetricTarget.tolerance(level: level, percent: MetricTarget.tolerancePercent)
            }) ?? false
            out.append(Metric(
                label: "Wall R−B",
                value: String(format: "%+.0f", w),
                target: haveGoodReference ? "colour is yours to choose" : "±20",
                status: haveGoodReference ? .info
                    : (abs(w) <= MetricTarget.tolerance(level: wall ?? 0,
                                                        percent: MetricTarget.tolerancePercent) ? .good : .warn)))
        }

        out.append(Metric(
            label: "Clipped",
            value: String(format: "%.2f%%", clipPct),
            target: "< 0.5%",
            status: clipPct <= MetricTarget.clipPctMax ? .good : .warn))

        out.append(Metric(
            label: "Crushed to black",
            value: String(format: "%.1f%%", crushPct),
            target: "< 5%",
            status: crushPct <= MetricTarget.crushPctMax ? .good : .warn))

        if let sharp = eyeSharpness {
            // No pass/fail: the number only means something relative to other
            // focus positions on the same scene, which is what the focus sweep
            // uses it for.
            out.append(Metric(
                label: "Eye sharpness",
                value: String(format: "%.1f", sharp),
                target: "higher = sharper",
                status: .info))
        }

        out.append(Metric(
            label: "Mean frame luma",
            value: String(format: "%.1f", meanLuma),
            target: "—",
            status: .info))

        return out
    }

    /// Compact form handed to the model so its verdict is grounded in the same
    /// numbers on screen, rather than in what a JPEG looks like to it.
    var promptSummary: String {
        var lines: [String] = []
        if faceFound {
            if let v = forehead {
                lines.append("forehead luma \(Int(v)) (target \(Int(MetricTarget.forehead.lowerBound))-\(Int(MetricTarget.forehead.upperBound)))")
            }
            if let k = cheekKey, let f = cheekFill {
                lines.append("lit cheek \(Int(k)), shadow cheek \(Int(f))")
            }
            if let r = keyFillRatio { lines.append("key:fill \(String(format: "%.1f", r)):1 (target 1.5-2.8)") }
            if let w = wall { lines.append("wall beside head \(Int(w))") }
            if let d = faceOverWall { lines.append("face minus wall \(Int(d)) (target >= +70)") }
            if let s = shirt { lines.append("top \(Int(s))") }
            if let d = shirtOverFace { lines.append("top minus face \(Int(d)) (want negative)") }
            if let s = shirtRB { lines.append("top R-B \(Int(s)) (near 0 if neutral top)") }
            if let w = wallRB { lines.append("wall R-B \(Int(w)) (near 0)") }
        } else {
            lines.append("NO FACE DETECTED - face metrics unavailable, judge framing from the image")
        }
        lines.append("mean frame luma \(String(format: "%.1f", meanLuma))")
        lines.append("clipped \(String(format: "%.2f", clipPct))% (target < 0.5)")
        lines.append("crushed to black \(String(format: "%.1f", crushPct))% (target < 5)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Measurement

enum FrameMetricsAnalyzer {
    static func measure(imageData: Data) -> FrameMetrics? {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = PixelBuffer(cgImage: cgImage) else { return nil }

        let (mean, clipPct, crushPct) = buffer.wholeFrameStats()
        let size = CGSize(width: cgImage.width, height: cgImage.height)

        guard let face = detectFace(in: cgImage),
              let anchors = FaceAnchors(observation: face, imageSize: size) else {
            return FrameMetrics(
                faceFound: false,
                forehead: nil, cheekKey: nil, cheekFill: nil,
                cheekLeft: nil, cheekRight: nil,
                shirt: nil, wall: nil, shirtRB: nil, wallRB: nil, eyeSharpness: nil,
                meanLuma: mean, clipPct: clipPct, crushPct: crushPct)
        }

        // Every offset below is in units of interocular distance, along axes
        // derived from the eye line — so a tilted head samples the same places
        // on the face rather than sliding onto hair or into shadow.
        let d = anchors.eyeDistance
        let radius = max(3, Int(d * 0.16))
        let box = face.boundingBox
        let w = Double(buffer.width), h = Double(buffer.height)

        let forehead = buffer.patch(at: anchors.browMid + anchors.up * (d * 0.55), r: radius)

        // Cheeks are measured as REGIONS, not points. Two point samples put the
        // whole key:fill verdict on two pixels' worth of face, and they landed
        // on a nostril once and inside the beard once — reading 1.1:1 for a
        // face that was visibly lit hard from one side. Averaging each cheek
        // over an area is stable against landmark jitter and a stray shadow.
        let faceHalfWidth = Double(box.width) * w * 0.5
        let cheeks = buffer.cheekMeans(anchors: anchors, faceHalfWidth: faceHalfWidth)
        let key = max(cheeks.a, cheeks.b)
        let fill = min(cheeks.a, cheeks.b)

        // Top: a wide band starting below the JAW, averaged. A single patch can
        // sit on a collar, a fold in shadow, or the microphone; a band across
        // the chest is what the garment actually looks like.
        let shirt = buffer.topBand(anchors: anchors)

        // Wall: whichever side of the frame has more room beside the head, well
        // clear of the subject so a chair back or a lamp is not read as wall.
        let faceLeft = box.minX * w
        let faceRight = (box.minX + box.width) * w
        let wallX = faceLeft > (w - faceRight) ? faceLeft * 0.35 : faceRight + (w - faceRight) * 0.65
        let wallY = min(h - 1, max(0, anchors.browMid.y))
        let wall = buffer.patch(at: CGPoint(x: wallX, y: wallY), r: radius)

        return FrameMetrics(
            faceFound: true,
            forehead: forehead.luma,
            cheekKey: key,
            cheekFill: fill,
            cheekLeft: cheeks.a,
            cheekRight: cheeks.b,
            shirt: shirt?.luma,
            wall: wall.luma,
            shirtRB: shirt?.rMinusB,
            wallRB: wall.rMinusB,
            eyeSharpness: buffer.eyeSharpness(anchors: anchors),
            meanLuma: mean,
            clipPct: clipPct,
            crushPct: crushPct)
    }

    private static func detectFace(in cgImage: CGImage) -> VNFaceObservation? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        // Largest face wins — a portrait on the wall behind is smaller than the
        // person sitting in front of the camera.
        return (request.results ?? [])
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
    }
}

/// Face geometry in top-left pixel space, with axes taken from the eye line so
/// head tilt does not move the sample points around the face.
struct FaceAnchors {
    let leftEye: CGPoint
    let rightEye: CGPoint
    let eyeMid: CGPoint
    let browMid: CGPoint
    /// Lowest point of the jawline. The top sample hangs off this rather than
    /// off a multiple of eye spacing — the latter lands on the NECK as soon as
    /// the head tips or the subject sits closer, and skin reads as a strongly
    /// warm "neutral reference", which then drags white balance with it.
    let chin: CGPoint?
    let up: CGPoint
    let right: CGPoint
    let eyeDistance: Double

    init?(observation: VNFaceObservation, imageSize: CGSize) {
        guard let landmarks = observation.landmarks,
              let le = FaceAnchors.centroid(landmarks.leftEye, imageSize),
              let re = FaceAnchors.centroid(landmarks.rightEye, imageSize),
              let lb = FaceAnchors.centroid(landmarks.leftEyebrow, imageSize),
              let rb = FaceAnchors.centroid(landmarks.rightEyebrow, imageSize) else { return nil }

        let dist = hypot(re.x - le.x, re.y - le.y)
        guard dist > 4 else { return nil }

        let mid = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
        let brow = CGPoint(x: (lb.x + rb.x) / 2, y: (lb.y + rb.y) / 2)

        // "Up" is defined by where the brows sit relative to the eyes, so it
        // stays correct for a tilted or slightly turned head.
        var upVec = CGPoint(x: brow.x - mid.x, y: brow.y - mid.y)
        let upLen = hypot(upVec.x, upVec.y)
        guard upLen > 0.5 else { return nil }
        upVec = CGPoint(x: upVec.x / upLen, y: upVec.y / upLen)

        self.leftEye = le
        self.rightEye = re
        self.eyeMid = mid
        self.browMid = brow
        // Largest y in top-left space is the lowest point on the face.
        self.chin = FaceAnchors.points(landmarks.faceContour, imageSize)?.max { $0.y < $1.y }
        self.up = upVec
        self.right = CGPoint(x: -upVec.y, y: upVec.x)
        self.eyeDistance = dist
    }

    /// Vision reports landmarks with the origin at bottom-left; the pixel
    /// buffer is top-left. Convert once, here.
    private static func points(_ region: VNFaceLandmarkRegion2D?, _ size: CGSize) -> [CGPoint]? {
        guard let pts = region?.pointsInImage(imageSize: size), !pts.isEmpty else { return nil }
        return pts.map { CGPoint(x: $0.x, y: size.height - $0.y) }
    }

    private static func centroid(_ region: VNFaceLandmarkRegion2D?, _ size: CGSize) -> CGPoint? {
        guard let pts = region?.pointsInImage(imageSize: size), !pts.isEmpty else { return nil }
        let sx = pts.reduce(0.0) { $0 + $1.x }
        let sy = pts.reduce(0.0) { $0 + $1.y }
        let n = Double(pts.count)
        return CGPoint(x: sx / n, y: size.height - sy / n)
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func * (p: CGPoint, s: Double) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }

// MARK: - Pixel access

/// RGBA8 copy of the frame. Row 0 is the top row of the image.
final class PixelBuffer {
    let width: Int
    let height: Int
    private let ptr: UnsafeMutablePointer<UInt8>

    init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        p.initialize(repeating: 0, count: w * h * 4)

        guard let ctx = CGContext(
            data: p,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            p.deallocate()
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        self.width = w
        self.height = h
        self.ptr = p
    }

    deinit { ptr.deallocate() }

    struct Sample {
        let r: Double, g: Double, b: Double
        var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var rMinusB: Double { r - b }
    }

    func patch(at p: CGPoint, r: Int) -> Sample {
        patch(x: Int(p.x.rounded()), y: Int(p.y.rounded()), r: r)
    }

    func patch(x: Int, y: Int, r: Int) -> Sample {
        let x0 = max(0, x - r), x1 = min(width - 1, x + r)
        let y0 = max(0, y - r), y1 = min(height - 1, y + r)
        guard x0 <= x1, y0 <= y1 else { return Sample(r: 0, g: 0, b: 0) }

        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for yy in y0...y1 {
            for xx in x0...x1 {
                let i = (yy * width + xx) * 4
                sr += Double(ptr[i]); sg += Double(ptr[i + 1]); sb += Double(ptr[i + 2])
                n += 1
            }
        }
        return Sample(r: sr / n, g: sg / n, b: sb / n)
    }

    /// Mean luma of each cheek, walked in face-axis coordinates so head tilt
    /// does not tip one cheek's window onto the background.
    ///
    /// The window sits below the eyes and above the beard line, and the middle
    /// is skipped — the nose is lit differently from either cheek and would
    /// pull both sides toward each other.
    func cheekMeans(anchors: FaceAnchors, faceHalfWidth: Double) -> (a: Double, b: Double) {
        let d = anchors.eyeDistance
        var sumA = 0.0, nA = 0.0, sumB = 0.0, nB = 0.0
        let step = max(1.0, d * 0.06)

        // The shadow lives on the OUTER cheek, so the window has to reach it:
        // an earlier version spanned 0.22-0.95 interocular and sat almost
        // entirely on the lit inner cheek, reporting 1.2:1 for a face a hand
        // measurement put at 3:1. The outer edge is capped against the face box
        // so a narrow face cannot push the window onto the background, which
        // would read as shadow and exaggerate the ratio instead.
        let innerU = 0.40 * d
        let outerU = min(1.20 * d, faceHalfWidth * 0.88)
        guard outerU > innerU else { return (0, 0) }

        var v = -1.30 * d
        while v <= -0.25 * d {
            var u = -outerU
            while u <= outerU {
                if abs(u) >= innerU {              // skip the nose
                    let p = anchors.eyeMid + anchors.right * u + anchors.up * v
                    let x = Int(p.x.rounded()), y = Int(p.y.rounded())
                    if x >= 0, x < width, y >= 0, y < height {
                        let i = (y * width + x) * 4
                        let l = 0.2126 * Double(ptr[i]) + 0.7152 * Double(ptr[i + 1]) + 0.0722 * Double(ptr[i + 2])
                        if u < 0 { sumA += l; nA += 1 } else { sumB += l; nB += 1 }
                    }
                }
                u += step
            }
            v += step
        }
        return (nA > 0 ? sumA / nA : 0, nB > 0 ? sumB / nB : 0)
    }

    /// Mean colour of a band across the chest, anchored below the jaw.
    func topBand(anchors: FaceAnchors) -> Sample? {
        let d = anchors.eyeDistance
        // Start a clear margin below the chin so a beard or collar shadow is
        // not sampled as fabric. Falls back to eye spacing only if the jawline
        // was not detected.
        let origin = anchors.chin ?? (anchors.eyeMid - anchors.up * (d * 1.9))
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        var v = -0.55 * d
        while v >= -1.45 * d {
            var u = -1.1 * d
            while u <= 1.1 * d {
                let p = origin + anchors.right * u + anchors.up * v
                let x = Int(p.x.rounded()), y = Int(p.y.rounded())
                if x >= 0, x < width, y >= 0, y < height {
                    let i = (y * width + x) * 4
                    sr += Double(ptr[i]); sg += Double(ptr[i + 1]); sb += Double(ptr[i + 2]); n += 1
                }
                u += max(1, d * 0.08)
            }
            v -= max(1, d * 0.08)
        }
        guard n > 24 else { return nil }
        return Sample(r: sr / n, g: sg / n, b: sb / n)
    }

    /// Normalised variance of the Laplacian across a band spanning both eyes.
    /// The standard passive-autofocus measure, restricted to the subject.
    func eyeSharpness(anchors: FaceAnchors) -> Double? {
        let d = anchors.eyeDistance
        guard d > 8 else { return nil }

        var values: [Double] = []
        var v = -0.30 * d
        while v <= 0.30 * d {
            var u = -0.95 * d
            while u <= 0.95 * d {
                let p = anchors.eyeMid + anchors.right * u + anchors.up * v
                let x = Int(p.x.rounded()), y = Int(p.y.rounded())
                if x >= 1, x < width - 1, y >= 1, y < height - 1 {
                    func luma(_ xx: Int, _ yy: Int) -> Double {
                        let i = (yy * width + xx) * 4
                        return 0.2126 * Double(ptr[i]) + 0.7152 * Double(ptr[i + 1]) + 0.0722 * Double(ptr[i + 2])
                    }
                    let lap = -4 * luma(x, y) + luma(x - 1, y) + luma(x + 1, y) + luma(x, y - 1) + luma(x, y + 1)
                    values.append(lap)
                }
                u += 1
            }
            v += 1
        }
        guard values.count > 32 else { return nil }

        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)

        // Normalise by the band's own brightness so a darker frame does not
        // read as softer. Focus sweeps hold exposure constant, but Measure does
        // not, and an un-normalised number would drift with the light.
        var lumaSum = 0.0, n = 0.0
        let r = Int(d * 0.5)
        let cx = Int(anchors.eyeMid.x), cy = Int(anchors.eyeMid.y)
        for yy in max(0, cy - r)...min(height - 1, cy + r) {
            for xx in max(0, cx - r)...min(width - 1, cx + r) {
                let i = (yy * width + xx) * 4
                lumaSum += 0.2126 * Double(ptr[i]) + 0.7152 * Double(ptr[i + 1]) + 0.0722 * Double(ptr[i + 2])
                n += 1
            }
        }
        let meanLuma = n > 0 ? lumaSum / n : 0
        guard meanLuma > 1 else { return nil }
        return variance / (meanLuma * meanLuma) * 1000
    }

    /// Mean luma, plus the share of pixels blown out or crushed to black.
    /// These need no face detection, so they survive a failed detect.
    func wholeFrameStats() -> (mean: Double, clipPct: Double, crushPct: Double) {
        var total = 0.0, clipped = 0.0, crushed = 0.0
        let n = Double(width * height)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let l = 0.2126 * Double(ptr[i]) + 0.7152 * Double(ptr[i + 1]) + 0.0722 * Double(ptr[i + 2])
            total += l
            if l > 250 { clipped += 1 }
            if l <= 5 { crushed += 1 }
        }
        return (total / n, clipped / n * 100, crushed / n * 100)
    }
}
