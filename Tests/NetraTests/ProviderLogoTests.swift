import AppKit
import SwiftUI
import XCTest
@testable import Netra

final class SVGPathDataTests: XCTestCase {
    func testAbsoluteAndRelativeSquaresMatch() throws {
        let absolute = try SVGPathData.path("M10 10 L20 10 L20 20 L10 20 Z")
        let relative = try SVGPathData.path("m10 10 l10 0 l0 10 l-10 0 z")
        let lines = try SVGPathData.path("M10,10H20V20H10Z")
        let relativeLines = try SVGPathData.path("m10 10h10v10h-10z")
        for path in [absolute, relative, lines, relativeLines] {
            assertRect(path.boundingRect, CGRect(x: 10, y: 10, width: 10, height: 10))
        }
    }

    func testImplicitLinetoAfterMoveto() throws {
        // Pairs after M are absolute linetos; pairs after m are relative.
        assertRect(try SVGPathData.path("M0 0 10 0 10 5Z").boundingRect, CGRect(x: 0, y: 0, width: 10, height: 5))
        assertRect(try SVGPathData.path("m1 1 10 0 0 5z").boundingRect, CGRect(x: 1, y: 1, width: 10, height: 5))
    }

    func testCompactNumberForms() throws {
        // `.5.5` is two numbers, `-` separates, exponents are numbers, and a
        // relative command after Z starts from the subpath's first point.
        assertRect(try SVGPathData.path("M.5.5L10.5-9.5").boundingRect, CGRect(x: 0.5, y: -9.5, width: 10, height: 10))
        assertRect(try SVGPathData.path("M1e1 0L2E1 1e-0").boundingRect, CGRect(x: 10, y: 0, width: 10, height: 1))
        assertRect(try SVGPathData.path("M5 5h10v10zl-5-5").boundingRect, CGRect(x: 0, y: 0, width: 15, height: 15))
    }

    func testSmoothCurvesReflectControlPoints() throws {
        // Cubic with controls at ±10 bulges 7.5; S mirrors the bulge.
        let cubic = try SVGPathData.path("M0 0C0 10 10 10 10 0S20-10 20 0")
        assertRect(cubic.boundingRect, CGRect(x: 0, y: -7.5, width: 20, height: 15))
        let relativeCubic = try SVGPathData.path("M0 0c0 10 10 10 10 0s10-10 10 0")
        assertRect(relativeCubic.boundingRect, CGRect(x: 0, y: -7.5, width: 20, height: 15))
        // Quadratic with a control at 10 bulges 5; T mirrors it.
        let quad = try SVGPathData.path("M0 0Q5 10 10 0T20 0")
        assertRect(quad.boundingRect, CGRect(x: 0, y: -5, width: 20, height: 10))
        let relativeQuad = try SVGPathData.path("M0 0q5 10 10 0t10 0")
        assertRect(relativeQuad.boundingRect, CGRect(x: 0, y: -5, width: 20, height: 10))
        // S without a preceding cubic uses the current point as control 1:
        // y(t) = 30t²(1-t), peaking at 40/9.
        let lone = try SVGPathData.path("M0 0S10 10 10 0")
        XCTAssertEqual(lone.boundingRect.maxY, 40.0 / 9, accuracy: 0.01)
    }

    func testArcsFollowSweepAndLargeArcFlags() throws {
        // Semicircle from (0,0) to (10,0), radius 5: sweep 1 goes through y=-5.
        let upper = try SVGPathData.path("M0 0A5 5 0 0 1 10 0")
        assertRect(upper.boundingRect, CGRect(x: 0, y: -5, width: 10, height: 5))
        // Unseparated flags, sweep 0: through y=+5.
        let lower = try SVGPathData.path("M0 0a5 5 0 1010 0")
        assertRect(lower.boundingRect, CGRect(x: 0, y: 0, width: 10, height: 5))
        // Radius 10 over a chord of 10: the center sits 5√3 off the chord, so
        // the small arc bulges 10 - 5√3 and the large arc 10 + 5√3.
        let small = try SVGPathData.path("M0 0A10 10 0 0 0 10 0")
        let large = try SVGPathData.path("M0 0A10 10 0 1 0 10 0")
        XCTAssertEqual(small.boundingRect.height, 10 - 5 * 3.0.squareRoot(), accuracy: 0.05)
        XCTAssertEqual(large.boundingRect.height, 10 + 5 * 3.0.squareRoot(), accuracy: 0.05)
        // Radii too small are scaled up to just reach the endpoint.
        let scaled = try SVGPathData.path("M0 0A1 1 0 0 1 10 0")
        XCTAssertEqual(scaled.boundingRect.height, 5, accuracy: 0.05)
        // Flags followed by a negative number, as in the OpenAI path.
        let negative = try SVGPathData.path("M10 0a5 5 0 0 0-10 0")
        XCTAssertEqual(negative.boundingRect.height, 5, accuracy: 0.05)
        // A zero radius degrades to a straight line.
        assertRect(try SVGPathData.path("M0 0A0 5 0 0 1 10 0").boundingRect, CGRect(x: 0, y: 0, width: 10, height: 0))
    }

    func testRejectsMalformedData() {
        for bad in ["L10 10", "M0 0 X5 5", "M0 0 L10", "M0 0 A5 5 0 2 0 10 0", "M0 0Z 5 5", "M0 0 L1-"] {
            XCTAssertThrowsError(try SVGPathData.path(bad), bad)
        }
        XCTAssertTrue(try SVGPathData.path("").isEmpty)
    }

    private func assertRect(_ rect: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.01, file: file, line: line)
    }
}

final class ProviderMarkTests: XCTestCase {
    func testEveryEmbeddedPathParsesAndFitsItsViewBox() throws {
        XCTAssertEqual(Set(ProviderMark.all.map(\.agent)), ["claude", "codex", "cursor", "copilot", "opencode"])
        for (agent, mark) in ProviderMark.all {
            // Brand files carry sub-pixel overshoot (Copilot's x = -0.02),
            // so allow 1% of the viewBox.
            let tolerance = max(mark.viewBox.width, mark.viewBox.height) * 0.01
            let allowed = mark.viewBox.insetBy(dx: -tolerance, dy: -tolerance)
            var union = CGRect.null
            for (index, layer) in mark.layers.enumerated() {
                let path = try SVGPathData.path(layer.data)
                XCTAssertFalse(path.isEmpty, "\(agent) layer \(index) is empty")
                let bounds = path.boundingRect
                XCTAssertGreaterThan(bounds.width * bounds.height, 0, "\(agent) layer \(index) has no area")
                XCTAssertTrue(allowed.contains(bounds), "\(agent) layer \(index) \(bounds) exceeds \(mark.viewBox)")
                union = union.union(bounds)
            }
            // The mark fills its viewBox along at least one axis, so nothing
            // collapsed during parsing.
            XCTAssertGreaterThan(
                max(union.width / mark.viewBox.width, union.height / mark.viewBox.height), 0.95, agent
            )
            XCTAssertEqual(ProviderMark.paths(for: agent)?.count, mark.layers.count, agent)
        }
    }

    func testLookupIsCaseInsensitiveAndOthersFallBack() {
        XCTAssertNotNil(ProviderMark.mark(for: "Claude"))
        XCTAssertNotNil(ProviderMark.paths(for: "CODEX"))
        for agent in ["gemini", "pi", "hermes", "cursor-grok-bot", "other", ""] {
            XCTAssertNil(ProviderMark.mark(for: agent), agent)
        }
    }

    func testBrandColorsMatchTheOfficialFiles() {
        XCTAssertEqual(ProviderMark.claude.layers[0].color, .fixed(0xD97757))
        XCTAssertEqual(ProviderMark.cursor.layers[0].color.hex(for: .light), 0x26251E)
        XCTAssertEqual(ProviderMark.cursor.layers[0].color.hex(for: .dark), 0xEDECEC)
        XCTAssertEqual(ProviderMark.codex.layers[0].color.hex(for: .dark), 0xFFFFFF)
        XCTAssertEqual(ProviderMark.opencode.layers[1].color.hex(for: .dark), 0xF1ECEC)
    }
}

/// Dev-only visual QA: every mark at 16, 26 and 64pt on black (dark scheme)
/// and on white (light scheme), rendered at 2x. Runs only when
/// NETRA_RENDER_DIR is set, e.g.
/// NETRA_RENDER_DIR=/tmp/netra-previews swift test --filter ProviderLogoRenderPreview
@MainActor
final class ProviderLogoRenderPreview: XCTestCase {
    func testRenderLogos() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["NETRA_RENDER_DIR"] else {
            throw XCTSkip("set NETRA_RENDER_DIR to render logo previews")
        }
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let agents = ProviderMark.all.map(\.agent) + ["gemini", "pi"]
        for (name, scheme, background) in [("black", ColorScheme.dark, Color.black), ("white", .light, .white)] {
            let sheet = VStack(alignment: .leading, spacing: 12) {
                ForEach(agents, id: \.self) { agent in
                    HStack(spacing: 16) {
                        ForEach([16, 26, 64] as [CGFloat], id: \.self) { size in
                            ProviderLogo(agent: agent, size: size)
                        }
                    }
                }
            }
            .padding(16)
            .background(background)
            .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return XCTFail("render failed") }
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try XCTUnwrap(data).write(to: URL(fileURLWithPath: outputDir).appendingPathComponent("provider-logos-\(name).png"))
        }
    }
}
