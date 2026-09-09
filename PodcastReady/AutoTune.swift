import AVFoundation
import Foundation

// "Magic fix": measure, adjust the camera, re-measure, until the metrics the
// camera can actually move are in range.
//
// The governing rule is that MOST OF THE METRICS ARE NOT CAMERA-FIXABLE. Key:fill
// is where the light is standing; face-minus-wall is how far the light is from
// the wall; shirt-minus-face is what you are wearing; crushed-to-black is an
// unlit corner of the room. Turning exposure up to chase any of those makes the
// picture worse and the number barely moves. So the loop drives three things and
// reports the rest as work for a human.
//
// It also never touches the Processing Unit `brightness` control. That is a
// digital lift: it raises the black point and flattens contrast without adding
// any real information. Only levers that change the light the sensor actually
// collects are in play — exposure time, then gain.

struct AutoTuneStep: Identifiable {
    let id = UUID()
    let iteration: Int
    let message: String
}

struct AutoTuneOutcome {
    var steps: [AutoTuneStep] = []
    var fixed: [String] = []
    var needsYou: [String] = []
    var finalMetrics: FrameMetrics?
    var reverted = false
}

actor AutoTuner {
    private let settleNanoseconds: UInt64 = 450_000_000   // camera needs a few frames to apply a write

    /// `capture` must return a fresh JPEG frame each call. `lightRead`/`lightWrite`
    /// are the Elgato brightness lever when a light is reachable.
    func run(camera: UVCCamera,
             capture: @escaping () async -> Data?,
             lightRead: (@Sendable () async -> Int?)? = nil,
             lightWrite: (@Sendable (Int) async -> Void)? = nil,
             maxLightBrightness: Int = 70,
             onStep: @escaping @Sendable (AutoTuneStep) -> Void) async -> AutoTuneOutcome {

        var outcome = AutoTuneOutcome()
        var iteration = 0

        func log(_ message: String) {
            iteration += 1
            let step = AutoTuneStep(iteration: iteration, message: message)
            outcome.steps.append(step)
            onStep(step)
        }

        func measure() async -> FrameMetrics? {
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            guard let data = await capture() else { return nil }
            return FrameMetricsAnalyzer.measure(imageData: data)
        }

        guard var metrics = await measure() else {
            log("Could not capture a frame to measure.")
            return outcome
        }
        guard metrics.faceFound else {
            log("No face detected — auto-tune needs a face to meter against.")
            outcome.finalMetrics = metrics
            return outcome
        }

        // ---- Phase 1: white balance ----------------------------------------
        // Nearly orthogonal to exposure, so it is settled first and then left
        // alone. Driven off a neutral reference in frame; R-B rises as the WB
        // setting rises, which makes it a clean monotonic search.
        let wb = camera.read(.whiteBalance)
        let wbAuto = camera.read(.whiteBalanceAuto)
        if wbAuto.isSupported && wbAuto.current == 1 {
            log("Auto white balance is ON — turning it off so the setting can be held.")
            camera.write(.whiteBalanceAuto, value: 0)
        }
        // The TOP only, never the wall. A wall is a valid neutral reference
        // right up until someone puts an RGB light on it, and then it reads
        // R-B -70 and auto-white-balance would chase that as if the camera were
        // wrong. A mid-tone top is lit by the key and stays neutral.
        if wb.isSupported, let start = metrics.shirtRB {
            // The aim is recomputed against each measurement's own level, so a
            // frame that gets darker mid-search does not silently change what
            // "warm" means.
            let startLevel = metrics.shirt ?? 0
            let aim = MetricTarget.warmthAim(level: startLevel)
            let autoTol = MetricTarget.tolerance(level: startLevel,
                                                 percent: MetricTarget.autoCorrectTolerancePercent)
            if abs(start - aim) <= autoTol {
                log(String(format: "White balance already on target (%.0f%% warm, aiming %.0f%%) — left at %d K.",
                           startLevel > 1 ? start / startLevel * 100 : 0, MetricTarget.warmthPercent, wb.current))
            } else {
                var lo = wb.minimum, hi = wb.maximum, best = wb.current, bestErr = abs(start - aim)
                var rounds = 0
                while lo <= hi && rounds < 7 {
                    rounds += 1
                    let mid = (lo + hi) / 2
                    camera.write(.whiteBalance, value: mid)
                    guard let m = await measure(), let rb = m.shirtRB else { break }
                    log(String(format: "WB %d K → neutral R−B %+.0f", mid, rb))
                    let level = m.shirt ?? 0
                    let stepAim = MetricTarget.warmthAim(level: level)
                    let stepTol = MetricTarget.tolerance(level: level,
                                                         percent: MetricTarget.autoCorrectTolerancePercent)
                    if abs(rb - stepAim) < bestErr { bestErr = abs(rb - stepAim); best = mid; metrics = m }
                    if abs(rb - stepAim) <= stepTol { break }
                    // Warmer than the aim => tell the camera the light is warmer
                    // by lowering the setting, and vice versa.
                    if rb > stepAim { hi = mid - wb.resolutionStep } else { lo = mid + wb.resolutionStep }
                }
                camera.write(.whiteBalance, value: best)
                if let m = await measure() { metrics = m }
                let finalLevel = metrics.shirt ?? 0
                if bestErr <= MetricTarget.tolerance(level: finalLevel,
                                                     percent: MetricTarget.autoCorrectTolerancePercent) {
                    outcome.fixed.append("White balance → \(best) K (top R−B \(Int(bestErr)) off target)")
                } else if bestErr <= MetricTarget.tolerance(level: finalLevel,
                                                            percent: MetricTarget.tolerancePercent) {
                    // Landed inside the "fine to look at" band but not on the
                    // tighter bar. That is a result, not a fault — saying
                    // "could not reach neutral" here would send someone hunting
                    // a daylight leak that isn't there.
                    outcome.fixed.append("White balance → \(best) K (top R−B \(Int(bestErr)), close enough)")
                } else {
                    outcome.needsYou.append("White balance could not reach neutral (best R−B \(Int(bestErr))) — daylight is probably leaking in; close the shutter.")
                }
            }
        } else if wb.isSupported {
            outcome.needsYou.append("No neutral reference in frame, so white balance was left alone. Wear a grey or white top and run this again.")
        }

        // ---- Phase 2: exposure ---------------------------------------------
        // Forehead luma rises monotonically with exposure time, so binary search
        // it. Gain is only reached for when exposure runs out of range, because
        // it buys brightness with noise.
        let exp = camera.read(.exposureTime)
        let aeMode = camera.read(.exposureAuto)
        if aeMode.isSupported && aeMode.current != 1 {
            log("Auto exposure is on — switching to manual so exposure can be held.")
            camera.write(.exposureAuto, value: 1)
            if let m = await measure() { metrics = m }
        }

        // Brightness is taken from the LIGHT before the camera wherever a light
        // is reachable. Measured on this rig: raising the Elgato 41% -> 50% lifted
        // the face +17 and the wall behind it only +8, because the key is aimed at
        // the subject and falls off before the wall. Exposure lifts both equally,
        // so it buys brightness at the cost of the separation we want.
        var handledByLight = false
        if let lightRead, let lightWrite, let start = await lightRead(),
           let forehead = metrics.forehead,
           !(MetricTarget.forehead.contains(forehead) && metrics.clipPct <= MetricTarget.clipPctMax) {

            // Aim LOW in the acceptable band, not at the middle of it, and do
            // not stop at the first value that merely qualifies. A face at 180
            // is no better than one at 165, and the difference is a light in
            // your eyes for an hour — the first version accepted whatever it
            // hit first and landed at 180 on a 55% -> 76% jump.
            let target = MetricTarget.foreheadTarget
            let tolerance = 6.0
            var lo = 3, hi = max(3, maxLightBrightness), best = start, bestErr = abs(forehead - target)
            var rounds = 0
            while lo <= hi && rounds < 7 {
                rounds += 1
                let mid = (lo + hi) / 2
                await lightWrite(mid)
                guard let m = await measure(), let f = m.forehead else { break }
                log(String(format: "Light %d%% → forehead %.0f, clipped %.2f%%", mid, f, m.clipPct))
                let err = m.clipPct > MetricTarget.clipPctMax ? Double.infinity : abs(f - target)
                if err < bestErr { bestErr = err; best = mid; metrics = m }
                if m.clipPct > MetricTarget.clipPctMax { hi = mid - 1; continue }
                if abs(f - target) <= tolerance { best = mid; metrics = m; break }
                if f < target { lo = mid + 1 } else { hi = mid - 1 }
            }
            await lightWrite(best)
            if let m = await measure() { metrics = m }

            if let f = metrics.forehead, MetricTarget.forehead.contains(f) {
                outcome.fixed.append("Light → \(best)% (forehead \(Int(f)))")
                handledByLight = true
            } else if best >= maxLightBrightness, let f = metrics.forehead, f < MetricTarget.forehead.lowerBound {
                // The ceiling is a comfort limit, not a hardware one, so this is
                // not a dead end — spend camera exposure instead. It lifts the
                // background too, which is affordable while face-minus-wall has
                // headroom.
                log("Light is at its \(maxLightBrightness)% ceiling and the face is \(Int(f)) — using exposure for the rest.")
            }
        }

        if !handledByLight, exp.isSupported, let forehead = metrics.forehead {
            if MetricTarget.forehead.contains(forehead) && metrics.clipPct <= MetricTarget.clipPctMax {
                log(String(format: "Exposure already good (forehead %.0f) — left at %d.", forehead, exp.current))
            } else {
                let target = MetricTarget.foreheadTarget
                var lo = exp.minimum, hi = exp.maximum
                var best = exp.current, bestErr = abs(forehead - target)
                var rounds = 0
                while lo <= hi && rounds < 8 {
                    rounds += 1
                    let mid = (lo + hi) / 2
                    camera.write(.exposureTime, value: mid)
                    guard let m = await measure(), let f = m.forehead else { break }
                    log(String(format: "Exposure %d → forehead %.0f, clipped %.2f%%", mid, f, m.clipPct))
                    // Clipping vetoes a value however good the forehead looks.
                    let err = m.clipPct > MetricTarget.clipPctMax ? Double.infinity : abs(f - target)
                    if err < bestErr { bestErr = err; best = mid; metrics = m }
                    if m.clipPct > MetricTarget.clipPctMax { hi = mid - 1; continue }
                    if MetricTarget.forehead.contains(f) { best = mid; metrics = m; break }
                    if f < target { lo = mid + 1 } else { hi = mid - 1 }
                }
                camera.write(.exposureTime, value: best)
                if let m = await measure() { metrics = m }

                if let f = metrics.forehead, MetricTarget.forehead.contains(f) {
                    outcome.fixed.append("Exposure → \(best) (forehead \(Int(f)))")
                } else if let f = metrics.forehead {
                    // Running out of BOTH levers is a finding, not a failure, and
                    // it needs to name the levers. "Could not land the face in
                    // range" tells you nothing you can act on. The near-max test
                    // is a fraction rather than equality: a binary search stops
                    // one or two steps short of the ceiling, so `== maximum`
                    // never fired and this branch was unreachable in practice.
                    let exposureMaxed = Double(best) >= Double(exp.maximum) * 0.97
                    let lightMaxed = (await lightRead?()) ?? 0 >= maxLightBrightness
                    if exposureMaxed && lightMaxed {
                        outcome.needsYou.append("Face is \(Int(f)), short of \(Int(MetricTarget.forehead.lowerBound)). Exposure is at maximum and the light is at your \(maxLightBrightness)% ceiling — raise the ceiling, move the light closer, or accept a slightly darker face. Swinging the key off-axis always costs brightness; that is the trade you just made for the shadow.")
                    } else if exposureMaxed {
                        outcome.needsYou.append("Face is \(Int(f)) with exposure at maximum — turn the light up, or raise the Magic Fix ceiling.")
                    } else {
                        outcome.needsYou.append("Could not land the face in range (best \(Int(f))).")
                    }
                }
            }
        }

        // ---- Phase 3: what neither the camera nor the light can fix ---------
        if let r = metrics.keyFillRatio, !MetricTarget.keyFill.contains(r) {
            if r < MetricTarget.keyFill.lowerBound {
                // Name the direction. "Move it off to one side" is unusable
                // advice at 1.0:1 — there is no visible asymmetry to reason
                // from, and moving the wrong way makes it flatter.
                let sides = (metrics.cheekLeft).flatMap { l in (metrics.cheekRight).map { rr in
                    String(format: " (left cheek %.0f, right %.0f)", l, rr) } } ?? ""
                if let side = metrics.keySide {
                    outcome.needsYou.append(String(format: "Key:fill is %.1f:1 — too flat%@. The light is favouring %@; move it FURTHER that way, around 45° off the lens.", r, sides, side))
                } else {
                    outcome.needsYou.append(String(format: "Key:fill is %.1f:1 — dead flat%@, so there is no side to favour yet. Swing the light well out to camera-left and re-measure.", r, sides))
                }
            } else {
                outcome.needsYou.append(String(format: "Key:fill is %.1f:1 — too contrasty. Add a white bounce card on the shadow side.", r))
            }
        }
        if let d = metrics.faceOverWall, d < MetricTarget.faceOverWallMin {
            outcome.needsYou.append("Face is only \(Int(d)) above the wall behind you — flag the light, or sit further forward.")
        }
        if let d = metrics.shirtOverFace, d >= 0 {
            outcome.needsYou.append("Your top is brighter than your face — no camera setting fixes that. Wear a mid-tone one.")
        }
        if metrics.crushPct > MetricTarget.crushPctMax {
            outcome.needsYou.append(String(format: "%.0f%% of the frame is crushed to black — put a dim light on the dark side of the room.", metrics.crushPct))
        }

        outcome.finalMetrics = metrics
        log(outcome.fixed.isEmpty ? "Nothing left for the camera to change." : "Done.")
        return outcome
    }
}

private extension UVCControlState {
    /// Step size for the binary search. Some controls (white balance) advertise
    /// a coarse resolution; stepping finer than that just wastes a round trip.
    var resolutionStep: Int { max(1, (maximum - minimum) / 128) }
}
