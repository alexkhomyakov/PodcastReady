import Foundation

// Autofocus that only cares about the plane your face is in.
//
// The camera's own autofocus maximises sharpness across the whole frame, and
// this room has far more high-frequency detail behind the subject than on him —
// framed art, dining chairs, and a microphone much closer to the lens than the
// face. That is why it grabs the wrong thing. This sweeps the focus motor and
// scores each position on the EYE BAND alone, so the winning position is the
// one that makes the subject crisp, whatever the rest of the frame does.
//
// It is "auto" in the sense that nobody has to judge crispness by eye, and
// "narrow" in the sense that a re-focus searches a small window around the last
// known-good position rather than the whole range.

struct FocusSample: Identifiable {
    let id = UUID()
    let position: Int
    let sharpness: Double
}

struct FocusResult {
    var samples: [FocusSample] = []
    var best: Int?
    var bestSharpness: Double?
    var previous: Int?
    var message: String = ""

    /// A sweep over a still subject should show one clear peak. A flat curve
    /// means the metric never found anything to lock onto — a blurred or absent
    /// face, or someone who moved — and its "best" is noise.
    var isConfident: Bool {
        guard samples.count >= 4, let peak = samples.map(\.sharpness).max() else { return false }
        let floor = samples.map(\.sharpness).min() ?? 0
        return peak > 0 && (peak - floor) / peak > 0.25
    }
}

actor FocusTuner {
    private let settle: UInt64 = 400_000_000

    /// `window` restricts the search to +/- that many steps around the current
    /// position. Nil sweeps the whole range.
    func find(camera: UVCCamera,
              capture: @escaping () async -> Data?,
              window: Int? = nil,
              onSample: @escaping @Sendable (FocusSample) -> Void) async -> FocusResult {

        var result = FocusResult()
        let control = camera.read(.focusAbsolute)
        guard control.isSupported else {
            result.message = "This camera has no manual focus control."
            return result
        }
        result.previous = control.current

        // Autofocus has to be off or the camera fights every position we set.
        let auto = camera.read(.focusAuto)
        if auto.isSupported && auto.current == 1 {
            camera.write(.focusAuto, value: 0)
        }

        func sharpness(at position: Int) async -> Double? {
            camera.write(.focusAbsolute, value: position)
            try? await Task.sleep(nanoseconds: settle)
            guard let data = await capture(),
                  let m = FrameMetricsAnalyzer.measure(imageData: data),
                  let s = m.eyeSharpness else { return nil }
            let sample = FocusSample(position: position, sharpness: s)
            result.samples.append(sample)
            onSample(sample)
            return s
        }

        // Search bounds
        var lo = control.minimum, hi = control.maximum
        if let window {
            lo = max(control.minimum, control.current - window)
            hi = min(control.maximum, control.current + window)
        }
        guard hi > lo else {
            result.message = "Focus range is empty."
            return result
        }

        // Coarse pass. 11 stops is enough to bracket the peak on a 450-step
        // range without the sweep taking a minute.
        let coarseСount = 11
        let step = max(1, (hi - lo) / (coarseСount - 1))
        var best = control.current
        var bestValue = -1.0

        var position = lo
        while position <= hi {
            if let s = await sharpness(at: position), s > bestValue { bestValue = s; best = position }
            position += step
        }

        guard bestValue > 0 else {
            camera.write(.focusAbsolute, value: control.current)
            result.message = "Could not measure sharpness — is a face visible and still?"
            return result
        }

        // Fine pass around the coarse winner.
        let fineLo = max(lo, best - step), fineHi = min(hi, best + step)
        let fineStep = max(1, (fineHi - fineLo) / 6)
        position = fineLo
        while position <= fineHi {
            if let s = await sharpness(at: position), s > bestValue { bestValue = s; best = position }
            position += fineStep
        }

        camera.write(.focusAbsolute, value: best)
        result.best = best
        result.bestSharpness = bestValue

        if !result.isConfident {
            // Refusing is better than confidently parking the motor somewhere
            // arbitrary: a flat curve means the measurement never saw focus
            // change anything.
            camera.write(.focusAbsolute, value: control.current)
            result.best = nil
            result.message = "No clear focus peak — the sweep looked flat. Sit still, make sure your face is lit and in frame, and try again. Focus left at \(control.current)."
            return result
        }

        let moved = abs(best - (result.previous ?? best))
        result.message = moved == 0
            ? "Already at the sharpest position (\(best))."
            : "Focus \(result.previous ?? 0) → \(best), \(String(format: "%.0f%%", (bestValue / max(sharpnessAt(result, result.previous)  , 0.0001) - 1) * 100)) sharper on the eyes."
        return result
    }

    private func sharpnessAt(_ result: FocusResult, _ position: Int?) -> Double {
        guard let position else { return 0 }
        return result.samples.first { $0.position == position }?.sharpness
            ?? result.samples.min { abs($0.position - position) < abs($1.position - position) }?.sharpness
            ?? 0
    }
}
