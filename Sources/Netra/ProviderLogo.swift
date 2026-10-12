import SwiftUI

/// A provider's own logo mark at the given size, drawn from the vector data
/// each company publishes. Providers without an official mark embedded here
/// fall back to a filled dot in their palette color.
///
/// Marks with light and dark variants follow `colorScheme`, so a surface
/// that is always dark (the notch island) should set
/// `.environment(\.colorScheme, .dark)` on its root.
struct ProviderLogo: View {
    var agent: String
    var size: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let mark = ProviderMark.mark(for: agent), let paths = ProviderMark.paths(for: agent) {
                ZStack {
                    ForEach(paths.indices, id: \.self) { index in
                        let layer = mark.layers[index]
                        ViewBoxShape(path: paths[index], viewBox: mark.viewBox)
                            .fill(layer.color.resolved(for: colorScheme), style: FillStyle(eoFill: layer.evenOdd))
                    }
                }
                .frame(width: size, height: size)
            } else {
                Circle()
                    .fill(AgentPalette.color(for: agent))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(AgentPalette.displayName(agent))
    }
}

/// Scales path data from its SVG viewBox into the frame, preserving the
/// aspect ratio and centering it (SVG's default `xMidYMid meet`).
private struct ViewBoxShape: Shape {
    var path: Path
    var viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let x = rect.minX + (rect.width - viewBox.width * scale) / 2 - viewBox.minX * scale
        let y = rect.minY + (rect.height - viewBox.height * scale) / 2 - viewBox.minY * scale
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
    }
}

/// Official vector marks, copied verbatim from each company's brand assets.
/// Brand colors live here, not in `AgentPalette`: palette colors are Netra's
/// identity colors for charts, these are the companies' own.
struct ProviderMark: Sendable {
    struct Layer: Sendable {
        var data: String
        var color: BrandColor
        var evenOdd = false
    }

    enum BrandColor: Sendable, Equatable {
        case fixed(UInt32)
        /// The brand's own variants for light and dark backgrounds.
        case adaptive(onLight: UInt32, onDark: UInt32)

        func hex(for scheme: ColorScheme) -> UInt32 {
            switch self {
            case .fixed(let rgb): rgb
            case .adaptive(let onLight, let onDark): scheme == .dark ? onDark : onLight
            }
        }

        func resolved(for scheme: ColorScheme) -> Color {
            let rgb = hex(for: scheme)
            return Color(
                .sRGB,
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255
            )
        }
    }

    var viewBox: CGRect
    var layers: [Layer]

    static func mark(for agent: String) -> ProviderMark? {
        switch agent.lowercased() {
        case "claude": claude
        case "codex": codex
        case "cursor": cursor
        case "copilot": copilot
        case "opencode": opencode
        default: nil
        }
    }

    static let all: [(agent: String, mark: ProviderMark)] = [
        ("claude", claude), ("codex", codex), ("cursor", cursor), ("copilot", copilot), ("opencode", opencode),
    ]

    /// Parsed layer paths, once per process. Missing only if embedded data
    /// were malformed, which the tests rule out; the view then shows the dot.
    static func paths(for agent: String) -> [Path]? {
        parsed[agent.lowercased()]
    }

    private static let parsed: [String: [Path]] = all.reduce(into: [:]) { result, entry in
        result[entry.agent] = try? entry.mark.layers.map { try SVGPathData.path($0.data) }
    }

    // Claude Code: Anthropic's Claude spark ("Claude Spark - Clay"). The
    // press kit's "Claude Code logo" is a spark + wordmark lockup; the spark
    // is the standalone mark. Clay #D97757 on any background.
    // Source: https://www.anthropic.com/press-kit (Anthropic media resources
    // zip → Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg).
    // Retrieved 2026-10-12.
    static let claude = ProviderMark(
        viewBox: CGRect(x: 0, y: 0, width: 94, height: 94),
        layers: [Layer(data: #"M18.7657 62.4437L37.1822 52.1167L37.4857 51.2122L37.1822 50.7085H36.2715L33.1852 50.5208L22.6615 50.2391L13.5545 49.8636L4.70044 49.3942L2.47428 48.9248L0.399902 46.1553L0.602281 44.794L2.47428 43.5266L5.15579 43.7613L11.0754 44.1837L19.98 44.794L26.4055 45.1695L35.9679 46.1553H37.4857L37.6881 45.545L37.1822 45.1695L36.7774 44.794L27.5692 38.5508L17.6021 31.9791L12.3908 28.1769L9.60812 26.2524L8.19147 24.4686L7.58433 20.5256L10.1141 17.7091L13.5545 17.9438L14.4146 18.1785L17.9056 20.8542L25.343 26.6279L35.0572 33.7629L36.4739 34.9364L37.0443 34.5514L37.1316 34.2792L36.4739 33.1996L31.212 23.6706L25.596 13.9539L23.0663 9.91695L22.4086 7.52296C22.1538 6.51831 22.0038 5.68714 22.0038 4.65957L24.8877 0.716544L26.5067 0.200195L30.4025 0.716544L32.0215 2.12477L34.4501 7.66379L38.3458 16.3478L44.4172 28.1769L46.188 31.6975L47.1493 34.9364L47.5035 35.9222H48.1106V35.3589L48.6166 28.6933L49.5273 20.5256L50.438 10.0108L50.7415 7.05356L52.2088 3.48605L55.1433 1.56148L57.42 2.64112L59.292 5.31674L59.039 7.05356L57.926 14.2824L55.7504 25.5952L54.3337 33.1996H55.1433L56.1046 32.2138L59.9497 27.1442L66.3752 19.0704L69.2085 15.8784L72.5478 12.3579L74.6728 10.668H78.7203L81.6548 15.0804L80.3394 19.6337L76.1906 24.8911L72.7502 29.3504L67.8172 35.9595L64.7562 41.2734L65.0307 41.7118L65.7681 41.6489L76.8989 39.255L82.9197 38.1753L90.1041 36.9549L93.3422 38.457L93.6963 40.006L92.4315 43.151L84.7411 45.0287L75.7353 46.8594L62.3244 50.0164L62.1759 50.1358L62.3512 50.3958L68.399 50.9432L70.9794 51.084H77.3037L89.0922 51.9759L92.1785 53.9944L93.9999 56.4822L93.6963 58.4068L88.9404 60.8008L82.5655 59.2987L67.6401 55.7312L62.5301 54.4638H61.8217V54.8862L66.0717 59.064L73.9139 66.1051L83.6786 75.2116L84.1845 77.4648L82.9197 79.2485L81.6042 79.0608L73.0032 72.5829L69.6639 69.6726L62.1759 63.3356H61.67V63.9928L63.3902 66.5276L72.5478 80.2812L73.0032 84.5059L72.3454 85.8672L69.9675 86.7121L67.3871 86.2427L61.9735 78.6852L56.4587 70.2359L52.0064 62.6315L51.4687 62.971L48.8189 91.2654L47.6047 92.7206L44.7714 93.8002L42.3934 92.0164L41.1286 89.1061L42.3934 83.3324L43.9113 75.8219L45.1255 69.8604L46.2386 62.4437L46.9184 59.9661L46.8583 59.8003L46.3153 59.8916L40.7238 67.5603L32.2239 79.0608L25.4948 86.2427L23.8758 86.8999L21.0931 85.4447L21.3461 82.863L22.9145 80.5629L32.2239 68.7338L37.8399 61.3641L41.4594 57.1337L41.4242 56.5218L41.2244 56.5048L16.489 72.6299L12.0873 73.1932L10.1647 71.4094L10.4176 68.4991L11.3283 67.5603L18.7657 62.4437Z"#, color: .fixed(0xD97757))]
    )

    // Codex: the OpenAI Blossom. OpenAI publishes no separate Codex mark in
    // vector form (openai.com/brand covers the Blossom and wordmark only, and
    // the openai/codex repository ships no Codex logo); OpenAI's own Codex
    // docs header uses the Blossom. Monochrome: black on light, white on dark,
    // never recolored.
    // Source: https://developers.openai.com/codex (header logo SVG).
    // Retrieved 2026-10-12.
    static let codex = ProviderMark(
        viewBox: CGRect(x: 0, y: 0, width: 24, height: 24),
        layers: [Layer(data: #"M22.418 9.822a5.903 5.903 0 0 0-.52-4.91 6.1 6.1 0 0 0-2.822-2.513 6.204 6.204 0 0 0-3.78-.389A6.055 6.055 0 0 0 13.232.518 6.129 6.129 0 0 0 10.726 0a6.185 6.185 0 0 0-3.615 1.153A6.052 6.052 0 0 0 4.88 4.187a6.102 6.102 0 0 0-2.344 1.018A6.008 6.008 0 0 0 .828 7.087a5.981 5.981 0 0 0 .754 7.09 5.904 5.904 0 0 0 .52 4.911 6.101 6.101 0 0 0 2.821 2.513 6.205 6.205 0 0 0 3.78.389 6.057 6.057 0 0 0 2.065 1.492 6.13 6.13 0 0 0 2.505.518 6.185 6.185 0 0 0 3.617-1.154 6.052 6.052 0 0 0 2.232-3.035 6.101 6.101 0 0 0 2.343-1.018 6.009 6.009 0 0 0 1.709-1.883 5.981 5.981 0 0 0-.756-7.088Zm-9.143 12.609a4.583 4.583 0 0 1-2.918-1.04c.037-.02.102-.056.144-.081l4.844-2.76a.783.783 0 0 0 .397-.68v-6.738L17.79 12.3a.072.072 0 0 1 .04.055v5.58a4.473 4.473 0 0 1-1.335 3.176 4.596 4.596 0 0 1-3.219 1.321Zm-9.793-4.127a4.432 4.432 0 0 1-.544-3.014c.036.021.099.06.144.085l4.843 2.76a.796.796 0 0 0 .795 0l5.913-3.369V17.1a.071.071 0 0 1-.029.062L9.708 19.95a4.617 4.617 0 0 1-3.458.447 4.556 4.556 0 0 1-2.768-2.093ZM2.208 7.872A4.527 4.527 0 0 1 4.58 5.9l-.002.164v5.52a.768.768 0 0 0 .397.68l5.913 3.369-2.047 1.166a.075.075 0 0 1-.069.006l-4.896-2.792a4.51 4.51 0 0 1-2.12-2.73 4.45 4.45 0 0 1 .452-3.411Zm16.818 3.861-5.913-3.368 2.047-1.166a.074.074 0 0 1 .07-.006l4.896 2.789a4.526 4.526 0 0 1 1.762 1.815 4.448 4.448 0 0 1-.418 4.808 4.556 4.556 0 0 1-2.049 1.494v-5.686a.767.767 0 0 0-.395-.68Zm2.038-3.025a6.874 6.874 0 0 0-.144-.085l-4.843-2.76a.797.797 0 0 0-.796 0L9.368 9.23V6.9a.072.072 0 0 1 .03-.062l4.895-2.787a4.608 4.608 0 0 1 4.885.207 4.51 4.51 0 0 1 1.599 1.955c.333.788.433 1.654.287 2.496ZM8.255 12.865 6.208 11.7a.071.071 0 0 1-.04-.056v-5.58c0-.854.248-1.69.713-2.412a4.54 4.54 0 0 1 1.913-1.658 4.614 4.614 0 0 1 4.85.616c-.037.02-.102.055-.144.08L8.657 5.452a.782.782 0 0 0-.398.68l-.004 6.734ZM9.367 10.5 12.001 9l2.633 1.5v3L12.001 15l-2.634-1.5v-3Z"#, color: .adaptive(onLight: 0x000000, onDark: 0xFFFFFF))]
    )

    // Cursor: the 2D cube. Brand kit variants CUBE_2D_LIGHT (#26251E, for
    // light backgrounds) and CUBE_2D_DARK (#EDECEC, for dark backgrounds)
    // share this path.
    // Source: https://cursor.com/brand (cursor-brand-assets.zip →
    // General Logos/Cube/SVG/). Retrieved 2026-10-12.
    static let cursor = ProviderMark(
        viewBox: CGRect(x: 0, y: 0, width: 466.73, height: 532.09),
        layers: [Layer(data: #"M457.43,125.94L244.42,2.96c-6.84-3.95-15.28-3.95-22.12,0L9.3,125.94c-5.75,3.32-9.3,9.46-9.3,16.11v247.99c0,6.65,3.55,12.79,9.3,16.11l213.01,122.98c6.84,3.95,15.28,3.95,22.12,0l213.01-122.98c5.75-3.32,9.3-9.46,9.3-16.11v-247.99c0-6.65-3.55-12.79-9.3-16.11h-.01ZM444.05,151.99l-205.63,356.16c-1.39,2.4-5.06,1.42-5.06-1.36v-233.21c0-4.66-2.49-8.97-6.53-11.31L24.87,145.67c-2.4-1.39-1.42-5.06,1.36-5.06h411.26c5.84,0,9.49,6.33,6.57,11.39h-.01Z"#, color: .adaptive(onLight: 0x26251E, onDark: 0xEDECEC))]
    )

    // GitHub Copilot: the Copilot icon. Black or white only, per GitHub's
    // logo rules.
    // Source: https://brand.github.com (GitHub_Logos.zip →
    // SVG/Copilot_Icon_Black.svg and Copilot_Icon_White.svg). Retrieved 2026-10-12.
    static let copilot = ProviderMark(
        viewBox: CGRect(x: 0, y: 0, width: 96, height: 96),
        layers: [
            Layer(data: #"M95.6877 67.9677C92.2446 73.9488 72.2522 88.0617 48 88.0617C23.7478 88.0617 3.75535 73.9488 0.312312 67.9677C0.0605215 67.5303 -0.0207525 67.031 -0.0207525 66.5263L-0.0207524 55.8787C-0.0207524 55.4373 0.0473833 54.9986 0.210699 54.5885C1.69959 50.8499 5.59895 45.4192 10.6313 43.9621C11.2985 42.2494 12.2867 39.7456 13.2087 37.8974C13.0543 36.4833 13 35.0248 13 33.5512C13 28.2274 14.1285 23.5576 17.5288 20.0801C19.117 18.4559 21.0876 17.21 23.4246 16.2735C29.0217 11.7264 36.992 7.90112 47.9136 7.90112C58.8352 7.90112 66.9783 11.7264 72.5754 16.2735C74.9124 17.21 76.883 18.4559 78.4712 20.0801C81.8715 23.5576 83 28.2274 83 33.5512C83 35.0248 82.9457 36.4833 82.7913 37.8974C83.7133 39.7456 84.7015 42.2494 85.3687 43.9621C90.401 45.4192 94.3004 50.8499 95.7893 54.5885C95.9526 54.9986 96.0208 55.4373 96.0208 55.8787L96.0208 66.5263C96.0208 67.031 95.9395 67.5303 95.6877 67.9677ZM51.253 32.2606C51.0828 30.9345 51.0018 29.747 50.9995 28.686L50.9995 28.6021C51.0048 25.5242 51.6776 23.5215 52.7524 22.2914C54.1172 20.7295 56.9379 19.5328 62.8829 20.1762C68.9059 20.828 72.2725 22.3229 74.1812 24.2749C76.0291 26.1648 76.9999 28.9922 76.9999 33.5512C76.9999 38.3951 76.3018 41.2568 74.767 42.9977C73.3075 44.6531 70.4335 46 64.1386 46C59.2994 46 56.5326 44.4261 54.7637 42.2493C52.8644 39.912 51.7955 36.4878 51.253 32.2606ZM44.747 32.2606C44.9172 30.9344 44.9982 29.747 45.0005 28.686L45.0005 28.6021C44.9952 25.5242 44.3224 23.5214 43.2476 22.2914C41.8828 20.7295 39.0621 19.5328 33.1171 20.1762C27.0941 20.828 23.7275 22.3229 21.8188 24.2749C19.9709 26.1647 19.0001 28.9922 19.0001 33.5512C19.0001 38.3951 19.6982 41.2568 21.233 42.9977C22.6925 44.6531 25.5665 46 31.8614 46C36.7006 46 39.4674 44.4261 41.2363 42.2493C43.1356 39.9119 44.2045 36.4878 44.747 32.2606ZM48.6889 43.9983C48.4592 43.9995 48.9185 43.9983 48.6889 43.9983C48.4594 43.9983 47.5408 43.9995 47.3111 43.9983C46.8877 44.7075 46.4168 45.3882 45.8926 46.0332C42.8139 49.8219 38.2182 52 31.8613 52C24.9615 52 19.9049 50.564 16.7324 46.9657C16.552 46.7611 16.3906 46.5469 16.3906 46.5469L16 46.9657L16 73.3023C21.7392 76.4213 34.0576 82.0184 48 82.0184C61.9424 82.0184 74.2608 76.4213 80 73.3023L80 46.9657L79.6094 46.5469C79.6094 46.5469 79.4772 46.728 79.2676 46.9657C76.0951 50.564 71.0385 52 64.1387 52C57.7818 52 53.1861 49.8219 50.1074 46.0332C49.5832 45.3882 49.1123 44.7075 48.6889 43.9983Z"#, color: .adaptive(onLight: 0x000000, onDark: 0xFFFFFF), evenOdd: true),
            Layer(data: #"M58 57C60.2091 57 62 58.7909 62 61L62 69C62 71.2092 60.2091 73 58 73C55.7909 73 54 71.2092 54 69L54 61C54 58.7909 55.7909 57 58 57Z"#, color: .adaptive(onLight: 0x000000, onDark: 0xFFFFFF), evenOdd: true),
            Layer(data: #"M38 57C40.2091 57 42 58.7909 42 61L42 69C42 71.2092 40.2091 73 38 73C35.7909 73 34 71.2092 34 69L34 61C34 58.7909 35.7909 57 38 57Z"#, color: .adaptive(onLight: 0x000000, onDark: 0xFFFFFF), evenOdd: true),
        ]
    )

    // OpenCode: the logo mark. opencode-logo-light.svg (for light
    // backgrounds) and opencode-logo-dark.svg (for dark backgrounds) share
    // these two paths; their full-viewBox luminance mask is a no-op and is
    // omitted.
    // Source: https://opencode.ai/brand (opencode-brand-assets.zip → Logo/).
    // Retrieved 2026-10-12.
    static let opencode = ProviderMark(
        viewBox: CGRect(x: 0, y: 0, width: 240, height: 300),
        layers: [
            Layer(data: #"M180 240H60V120H180V240Z"#, color: .adaptive(onLight: 0xCFCECD, onDark: 0x4B4646)),
            Layer(data: #"M180 60H60V240H180V60ZM240 300H0V0H240V300Z"#, color: .adaptive(onLight: 0x211E1E, onDark: 0xF1ECEC)),
        ]
    )
}
