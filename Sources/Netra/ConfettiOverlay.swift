import SwiftUI

/// A lightweight, dependency-free confetti burst drawn in a Canvas. Bumping
/// `trigger` fires one ~2.3s burst; between bursts nothing animates and no
/// timeline runs, so it costs nothing at rest. Purely decorative — it never
/// intercepts clicks.
struct ConfettiOverlay: View {
    var trigger: Int
    /// Piece count — small for the popover, large for a full screen.
    var pieceCount: Int
    /// When set, draws a single static frame at this elapsed time instead of
    /// animating — used only to capture a representative frame offscreen.
    var previewElapsed: Double?

    @State private var start: Date?
    @State private var pieces: [Piece] = []

    init(trigger: Int, pieceCount: Int = 220, previewElapsed: Double? = nil) {
        self.trigger = trigger
        self.pieceCount = pieceCount
        self.previewElapsed = previewElapsed
    }

    private struct Piece {
        var x: CGFloat            // 0…1 across the width
        var delay: Double
        var fall: CGFloat         // vertical speed factor
        var drift: CGFloat        // horizontal sway amplitude
        var driftRate: Double
        var spin: Double          // radians / second, signed
        var size: CGFloat
        var color: Color
        var isRect: Bool
    }

    private static let colors: [Color] = [
        Color(red: 0.22, green: 0.53, blue: 0.90),
        Color(red: 0.83, green: 0.36, blue: 0.20),
        Color(red: 0.11, green: 0.69, blue: 0.48),
        Color(red: 0.93, green: 0.63, blue: 0.00),
        Color(red: 0.91, green: 0.48, blue: 0.64),
        Color(red: 0.57, green: 0.52, blue: 0.91),
    ]

    var body: some View {
        Group {
            if let previewElapsed {
                // Deterministic pieces so a static capture is reproducible.
                let previewPieces = Self.makePieces(seed: 7, count: pieceCount)
                Canvas { canvas, size in
                    draw(pieces: previewPieces, in: &canvas, size: size, elapsed: previewElapsed)
                }
            } else if let start {
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
                        draw(pieces: pieces, in: &canvas, size: size, elapsed: context.date.timeIntervalSince(start))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        pieces = Self.makePieces(seed: UInt64.random(in: .min ... .max), count: pieceCount)
        start = .now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.3))
            start = nil
        }
    }

    private static func makePieces(seed: UInt64, count: Int) -> [Piece] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in
            Piece(
                x: .random(in: 0.04...0.96, using: &rng),
                delay: .random(in: 0...0.35, using: &rng),
                fall: .random(in: 0.85...1.35, using: &rng),
                drift: .random(in: 10...34, using: &rng),
                driftRate: .random(in: 1.4...3.0, using: &rng),
                spin: .random(in: -6...6, using: &rng),
                size: .random(in: 5...9, using: &rng),
                color: colors[Int.random(in: 0..<colors.count, using: &rng)],
                isRect: Bool.random(using: &rng)
            )
        }
    }

    private func draw(pieces: [Piece], in canvas: inout GraphicsContext, size: CGSize, elapsed t: Double) {
        for piece in pieces {
            let tt = t - piece.delay
            guard tt >= 0 else { continue }
            // Gravity-ish fall down the popover height, plus a gentle sway.
            let progress = tt / 1.9
            let y = -12 + CGFloat(progress) * (size.height + 24) * piece.fall
            guard y < size.height + 12 else { continue }
            let x = piece.x * size.width + sin(tt * piece.driftRate) * piece.drift
            let opacity = tt < 1.5 ? 1.0 : max(0, 1 - (tt - 1.5) / 0.7)

            var ctx = canvas
            ctx.opacity = opacity
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: .radians(piece.spin * tt))
            let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2,
                              width: piece.size, height: piece.size * (piece.isRect ? 0.6 : 1))
            let path = piece.isRect
                ? Path(roundedRect: rect, cornerRadius: 1)
                : Path(ellipseIn: rect)
            ctx.fill(path, with: .color(piece.color))
        }
    }
}

/// Small deterministic RNG so a preview frame is reproducible; the live burst
/// seeds it randomly.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
