import Foundation

/// A single biquad IIR filter (RBJ Audio-EQ cookbook), transposed Direct Form II.
///
/// Allocation-free and stateful: hold one per channel and call `process` per sample in the
/// real-time path. Coefficients are normalized by `a0` at design time so the hot loop is
/// five multiplies and four adds.
public struct Biquad {
    // Normalized coefficients (a0 == 1).
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    // State (transposed DF-II).
    private var z1: Float = 0, z2: Float = 0

    public init() {}

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() { z1 = 0; z2 = 0 }

    private mutating func set(_ b0: Float, _ b1: Float, _ b2: Float, _ a0: Float, _ a1: Float, _ a2: Float) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0
        self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    // MARK: - Designers (RBJ cookbook)

    public mutating func setHighpass(freq: Float, q: Float, sampleRate: Float) {
        let w0 = 2 * Float.pi * freq / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        set((1 + cw) / 2, -(1 + cw), (1 + cw) / 2,
            1 + alpha, -2 * cw, 1 - alpha)
    }

    public mutating func setLowpass(freq: Float, q: Float, sampleRate: Float) {
        let w0 = 2 * Float.pi * freq / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        set((1 - cw) / 2, 1 - cw, (1 - cw) / 2,
            1 + alpha, -2 * cw, 1 - alpha)
    }

    public mutating func setPeaking(freq: Float, q: Float, gainDb: Float, sampleRate: Float) {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        set(1 + alpha * A, -2 * cw, 1 - alpha * A,
            1 + alpha / A, -2 * cw, 1 - alpha / A)
    }

    public mutating func setLowShelf(freq: Float, gainDb: Float, sampleRate: Float, slope: Float = 1) {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let twoSqrtAalpha = 2 * sqrt(A) * alpha
        set(A * ((A + 1) - (A - 1) * cw + twoSqrtAalpha),
            2 * A * ((A - 1) - (A + 1) * cw),
            A * ((A + 1) - (A - 1) * cw - twoSqrtAalpha),
            (A + 1) + (A - 1) * cw + twoSqrtAalpha,
            -2 * ((A - 1) + (A + 1) * cw),
            (A + 1) + (A - 1) * cw - twoSqrtAalpha)
    }

    public mutating func setHighShelf(freq: Float, gainDb: Float, sampleRate: Float, slope: Float = 1) {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let twoSqrtAalpha = 2 * sqrt(A) * alpha
        set(A * ((A + 1) + (A - 1) * cw + twoSqrtAalpha),
            -2 * A * ((A - 1) + (A + 1) * cw),
            A * ((A + 1) + (A - 1) * cw - twoSqrtAalpha),
            (A + 1) - (A - 1) * cw + twoSqrtAalpha,
            2 * ((A - 1) - (A + 1) * cw),
            (A + 1) - (A - 1) * cw - twoSqrtAalpha)
    }
}

/// One-pole envelope follower with separate attack/release time constants.
/// Tracks the peak magnitude of a signal for compressor/de-esser side-chains.
public struct EnvelopeFollower {
    private var env: Float = 0
    private var attackCoef: Float = 0
    private var releaseCoef: Float = 0

    public init() {}

    public mutating func configure(attackMs: Float, releaseMs: Float, sampleRate: Float) {
        attackCoef = exp(-1 / (attackMs * 0.001 * sampleRate))
        releaseCoef = exp(-1 / (releaseMs * 0.001 * sampleRate))
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let mag = abs(x)
        let coef = mag > env ? attackCoef : releaseCoef
        env = coef * (env - mag) + mag
        return env
    }

    public mutating func reset() { env = 0 }
}
