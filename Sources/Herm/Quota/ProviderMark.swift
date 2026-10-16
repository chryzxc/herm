import AppKit
import SwiftUI

/// Vector provider marks for compact quota surfaces. Paths come from the
/// CC0 Simple Icons set and MIT LobeHub icons (Z.ai, Antigravity, DeepSeek,
/// Kimi, OpenRouter), all on a 24 × 24 view box, so they scale crisply and
/// take the theme's foreground color instead of shipping fixed-color bitmaps.
enum ProviderMark: Equatable {
    case claude, openAI, openCode, zai, antigravity, deepSeek, kimi, openRouter
    /// A bundled LobeHub SVG in Resources/ProviderIcons; `-color` names keep
    /// their brand colors, the rest are monochrome and follow the theme.
    case icon(String)
    case monogram(String)

    /// Maps a quota provider identifier, including dynamic account suffixes
    /// such as `codex-hermes-<pool entry id>`, to its mark.
    init(providerID: String, displayName: String) {
        switch providerID {
        case "claude": self = .claude
        case let id where id == "codex" || id.hasPrefix("codex-"): self = .openAI
        case "opencode": self = .openCode
        case "glm": self = .zai
        case "antigravity": self = .antigravity
        case "deepseek": self = .deepSeek
        case "kimi": self = .kimi
        case "openrouter": self = .openRouter
        default: self = .monogram(String(displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
        }
    }
}

extension ProviderMark {
    /// Maps a Hermes provider name from the usage report (`openai-codex`,
    /// `claude-subscription-…`, `kimi-coding`…) to its mark.
    init(hermesProvider name: String) {
        let id = name.lowercased()
        switch id {
        case _ where id.hasPrefix("claude") || id.hasPrefix("anthropic"): self = .claude
        case _ where id.hasPrefix("openai") || id.hasPrefix("codex"): self = .openAI
        case _ where id.hasPrefix("opencode"): self = .openCode
        case _ where id.hasPrefix("zai") || id.hasPrefix("glm"): self = .zai
        case _ where id.hasPrefix("antigravity"): self = .antigravity
        case _ where id.hasPrefix("deepseek"): self = .deepSeek
        case _ where id.hasPrefix("kimi") || id.hasPrefix("moonshot"): self = .kimi
        case _ where id.hasPrefix("openrouter"): self = .openRouter
        default:
            let icon = Self.bundledIcons.first { prefixes, _ in prefixes.contains { id.hasPrefix($0) } }?.icon
            self = icon.map(Self.icon) ?? .monogram(String(id.prefix(1)).uppercased())
        }
    }

    /// Hermes provider slug prefixes → bundled icon. Providers without one
    /// (Mixture of Agents, GMI…) keep the letter tile.
    private static let bundledIcons: [(prefixes: [String], icon: String)] = [
        (["nous"], "nousresearch"),
        (["fireworks"], "fireworks-color"),
        (["novita"], "novita-color"),
        (["lmstudio"], "lmstudio"),
        (["alibaba", "qwen", "dashscope"], "qwen-color"),
        (["xai", "grok"], "xai"),
        (["xiaomi"], "xiaomimimo"),
        (["tencent"], "tencent-color"),
        (["nvidia"], "nvidia-color"),
        (["copilot", "github"], "githubcopilot"),
        (["huggingface"], "huggingface-color"),
        (["gemini", "google"], "gemini"),
        (["vertex"], "vertexai-color"),
        (["stepfun"], "stepfun-color"),
        (["minimax"], "minimax-color"),
        (["ollama"], "ollama"),
        (["arcee"], "arcee-color"),
        (["kilocode"], "kilocode"),
        (["bedrock", "aws"], "bedrock-color"),
        (["azure"], "azureai-color"),
        (["ai-gateway", "vercel"], "vercel"),
    ]

    private static let bundle: Bundle = Bundle.main.resourceURL.flatMap {
        Bundle(url: $0.appendingPathComponent("Herm_Herm.bundle"))
    } ?? Bundle.module

    // NSCache is thread-safe; images are read-only once cached.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = bundle.url(forResource: name, withExtension: "svg", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = !name.hasSuffix("-color")
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

/// A provider mark on a small rounded tile that follows the selected theme.
struct ProviderMarkBadge: View {
    let mark: ProviderMark
    var size: CGFloat = 20

    var body: some View {
        DockThemeShape(cornerRadius: size * 0.28)
            .fill(Color.dockSurface4)
            .overlay {
                switch mark {
                case .icon(let name):
                    if let image = ProviderMark.image(named: name) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .foregroundStyle(Color.dockPrimaryText)
                            .padding(size * 0.18)
                    } else {
                        monogram(String(name.prefix(1)).uppercased())
                    }
                case .monogram(let letter):
                    monogram(letter)
                case .claude:
                    ProviderMarkShape(path: ProviderMarkShape.claude)
                        // Claude's coral reads on both light and dark canvases.
                        .fill(Color(red: 0.851, green: 0.467, blue: 0.341))
                        .padding(size * 0.18)
                case .openAI:
                    ProviderMarkShape(path: ProviderMarkShape.openAI)
                        .fill(Color.dockPrimaryText)
                        .padding(size * 0.18)
                case .openCode:
                    ProviderMarkShape(path: ProviderMarkShape.openCode)
                        .fill(Color.dockPrimaryText)
                        .padding(size * 0.22)
                case .zai:
                    ProviderMarkShape(path: ProviderMarkShape.zai)
                        .fill(Color.dockPrimaryText)
                        .padding(size * 0.2)
                case .antigravity:
                    ProviderMarkShape(path: ProviderMarkShape.antigravity)
                        .fill(Color.dockPrimaryText)
                        .padding(size * 0.18)
                case .deepSeek:
                    // DeepSeek's whale blue reads on both light and dark canvases.
                    ProviderMarkShape(path: ProviderMarkShape.deepSeek)
                        .fill(Color(red: 0.302, green: 0.420, blue: 0.996), style: FillStyle(eoFill: true))
                        .padding(size * 0.18)
                case .kimi:
                    ProviderMarkShape(path: ProviderMarkShape.kimi)
                        .fill(Color.dockPrimaryText, style: FillStyle(eoFill: true))
                        .padding(size * 0.2)
                case .openRouter:
                    ProviderMarkShape(path: ProviderMarkShape.openRouter)
                        .fill(Color.dockPrimaryText, style: FillStyle(eoFill: true))
                        .padding(size * 0.18)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func monogram(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(Color.dockSecondaryText)
    }
}

struct ProviderMarkShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return path.applying(
            CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
                .scaledBy(x: scale, y: scale)
        )
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static let claude: Path = {
        var path = Path()
        path.move(to: p(4.7144, 15.9555))
        path.addLine(to: p(9.4318, 13.3084))
        path.addLine(to: p(9.5108, 13.0777))
        path.addLine(to: p(9.4318, 12.9502))
        path.addLine(to: p(9.2011, 12.9502))
        path.addLine(to: p(8.4118, 12.9016))
        path.addLine(to: p(5.7162, 12.8287))
        path.addLine(to: p(3.3787, 12.7316))
        path.addLine(to: p(1.1141, 12.6102))
        path.addLine(to: p(0.5434, 12.4887))
        path.addLine(to: p(0.0091, 11.7845))
        path.addLine(to: p(0.0637, 11.4323))
        path.addLine(to: p(0.5434, 11.1105))
        path.addLine(to: p(1.2294, 11.1713))
        path.addLine(to: p(2.7473, 11.2745))
        path.addLine(to: p(5.024, 11.4323))
        path.addLine(to: p(6.6754, 11.5295))
        path.addLine(to: p(9.1222, 11.7845))
        path.addLine(to: p(9.5108, 11.7845))
        path.addLine(to: p(9.5654, 11.6266))
        path.addLine(to: p(9.4318, 11.5295))
        path.addLine(to: p(9.3286, 11.4323))
        path.addLine(to: p(6.973, 9.8356))
        path.addLine(to: p(4.423, 8.1477))
        path.addLine(to: p(3.0874, 7.1763))
        path.addLine(to: p(2.3649, 6.6845))
        path.addLine(to: p(2.0006, 6.2231))
        path.addLine(to: p(1.8428, 5.2153))
        path.addLine(to: p(2.4985, 4.4928))
        path.addLine(to: p(3.3788, 4.5535))
        path.addLine(to: p(3.6034, 4.6142))
        path.addLine(to: p(4.4959, 5.3002))
        path.addLine(to: p(6.4023, 6.7756))
        path.addLine(to: p(8.8916, 8.6092))
        path.addLine(to: p(9.2559, 8.9127))
        path.addLine(to: p(9.4016, 8.8095))
        path.addLine(to: p(9.4198, 8.7367))
        path.addLine(to: p(9.2558, 8.4634))
        path.addLine(to: p(7.9019, 6.0167))
        path.addLine(to: p(6.4569, 3.5274))
        path.addLine(to: p(5.8134, 2.4954))
        path.addLine(to: p(5.6434, 1.876))
        path.addCurve(to: p(5.5402, 1.1475), control1: p(5.5827, 1.621), control2: p(5.5402, 1.4086))
        path.addLine(to: p(6.287, 0.1335))
        path.addLine(to: p(6.6997, 0))
        path.addLine(to: p(7.6954, 0.1336))
        path.addLine(to: p(8.1144, 0.4978))
        path.addLine(to: p(8.7336, 1.9125))
        path.addLine(to: p(9.7354, 4.1407))
        path.addLine(to: p(11.2897, 7.1703))
        path.addLine(to: p(11.745, 8.0688))
        path.addLine(to: p(11.9879, 8.9006))
        path.addLine(to: p(12.0789, 9.1556))
        path.addLine(to: p(12.2368, 9.1556))
        path.addLine(to: p(12.2368, 9.0099))
        path.addLine(to: p(12.3643, 7.3039))
        path.addLine(to: p(12.6011, 5.2092))
        path.addLine(to: p(12.8318, 2.5135))
        path.addLine(to: p(12.9107, 1.7546))
        path.addLine(to: p(13.2871, 0.8439))
        path.addLine(to: p(14.0339, 0.3521))
        path.addLine(to: p(14.6167, 0.6314))
        path.addLine(to: p(15.0964, 1.3174))
        path.addLine(to: p(15.0296, 1.7607))
        path.addLine(to: p(14.7443, 3.6124))
        path.addLine(to: p(14.1857, 6.5145))
        path.addLine(to: p(13.8214, 8.4574))
        path.addLine(to: p(14.0339, 8.4574))
        path.addLine(to: p(14.2768, 8.2145))
        path.addLine(to: p(15.2603, 6.9092))
        path.addLine(to: p(16.9117, 4.8449))
        path.addLine(to: p(17.6403, 4.0253))
        path.addLine(to: p(18.4903, 3.1207))
        path.addLine(to: p(19.0367, 2.6896))
        path.addLine(to: p(20.0688, 2.6896))
        path.addLine(to: p(20.8278, 3.8189))
        path.addLine(to: p(20.4878, 4.9846))
        path.addLine(to: p(19.4253, 6.3324))
        path.addLine(to: p(18.5449, 7.4738))
        path.addLine(to: p(17.2821, 9.1738))
        path.addLine(to: p(16.4928, 10.5338))
        path.addLine(to: p(16.5657, 10.6431))
        path.addLine(to: p(16.7539, 10.6248))
        path.addLine(to: p(19.6074, 10.0178))
        path.addLine(to: p(21.1495, 9.7384))
        path.addLine(to: p(22.9891, 9.4227))
        path.addLine(to: p(23.8209, 9.8113))
        path.addLine(to: p(23.9119, 10.2059))
        path.addLine(to: p(23.5841, 11.0134))
        path.addLine(to: p(21.6171, 11.4991))
        path.addLine(to: p(19.3099, 11.9605))
        path.addLine(to: p(15.8735, 12.7741))
        path.addLine(to: p(15.831, 12.8045))
        path.addLine(to: p(15.8796, 12.8652))
        path.addLine(to: p(17.4278, 13.0109))
        path.addLine(to: p(18.0896, 13.0473))
        path.addLine(to: p(19.7106, 13.0473))
        path.addLine(to: p(22.7281, 13.272))
        path.addLine(to: p(23.5173, 13.794))
        path.addLine(to: p(23.9909, 14.4316))
        path.addLine(to: p(23.9119, 14.9173))
        path.addLine(to: p(22.6977, 15.5366))
        path.addLine(to: p(21.0584, 15.148))
        path.addLine(to: p(17.2334, 14.2373))
        path.addLine(to: p(15.9221, 13.9094))
        path.addLine(to: p(15.7399, 13.9094))
        path.addLine(to: p(15.7399, 14.0187))
        path.addLine(to: p(16.8328, 15.0873))
        path.addLine(to: p(18.8363, 16.8965))
        path.addLine(to: p(21.3438, 19.2279))
        path.addLine(to: p(21.4713, 19.8047))
        path.addLine(to: p(21.1495, 20.2601))
        path.addLine(to: p(20.8095, 20.2115))
        path.addLine(to: p(18.6056, 18.554))
        path.addLine(to: p(17.7556, 17.8072))
        path.addLine(to: p(15.831, 16.1862))
        path.addLine(to: p(15.7035, 16.1862))
        path.addLine(to: p(15.7035, 16.3562))
        path.addLine(to: p(16.1467, 17.0058))
        path.addLine(to: p(18.4903, 20.5272))
        path.addLine(to: p(18.6117, 21.6079))
        path.addLine(to: p(18.4417, 21.96))
        path.addLine(to: p(17.8346, 22.1725))
        path.addLine(to: p(17.1667, 22.0511))
        path.addLine(to: p(15.7946, 20.1265))
        path.addLine(to: p(14.38, 17.959))
        path.addLine(to: p(13.2386, 16.0162))
        path.addLine(to: p(13.0989, 16.0952))
        path.addLine(to: p(12.4249, 23.3504))
        path.addLine(to: p(12.1093, 23.7207))
        path.addLine(to: p(11.3807, 24))
        path.addLine(to: p(10.7736, 23.5386))
        path.addLine(to: p(10.4518, 22.7918))
        path.addLine(to: p(10.7736, 21.3165))
        path.addLine(to: p(11.1622, 19.3919))
        path.addLine(to: p(11.4779, 17.8619))
        path.addLine(to: p(11.7632, 15.9615))
        path.addLine(to: p(11.9332, 15.3301))
        path.addLine(to: p(11.9211, 15.2876))
        path.addLine(to: p(11.7814, 15.3058))
        path.addLine(to: p(10.3486, 17.273))
        path.addLine(to: p(8.169, 20.2176))
        path.addLine(to: p(6.4447, 22.0632))
        path.addLine(to: p(6.0319, 22.2272))
        path.addLine(to: p(5.3155, 21.8568))
        path.addLine(to: p(5.3822, 21.195))
        path.addLine(to: p(5.783, 20.6061))
        path.addLine(to: p(8.169, 17.5704))
        path.addLine(to: p(9.6079, 15.6884))
        path.addLine(to: p(10.5369, 14.6016))
        path.addLine(to: p(10.5307, 14.4437))
        path.addLine(to: p(10.4761, 14.4437))
        path.addLine(to: p(4.1376, 18.5601))
        path.addLine(to: p(3.0083, 18.7058))
        path.addLine(to: p(2.5226, 18.2504))
        path.addLine(to: p(2.5834, 17.5037))
        path.addLine(to: p(2.8141, 17.2608))
        path.addLine(to: p(4.7205, 15.9494))
        path.closeSubpath()
        return path
    }()

    static let openAI: Path = {
        var path = Path()
        path.move(to: p(22.2819, 9.8211))
        path.addCurve(to: p(21.7662, 4.9103), control1: p(22.8248, 8.1862), control2: p(22.6369, 6.3967))
        path.addCurve(to: p(15.2564, 2.0103), control1: p(20.4571, 2.6316), control2: p(17.826, 1.4595))
        path.addCurve(to: p(9.492, 0.1311), control1: p(13.8083, 0.3995), control2: p(11.6112, -0.3168))
        path.addCurve(to: p(4.9807, 4.1818), control1: p(7.3728, 0.5789), control2: p(5.6533, 2.1229))
        path.addCurve(to: p(0.983, 7.0818), control1: p(3.2928, 4.5279), control2: p(1.836, 5.5847))
        path.addCurve(to: p(1.7257, 14.1784), control1: p(-0.3404, 9.3568), control2: p(-0.0401, 12.2267))
        path.addCurve(to: p(2.2367, 19.0891), control1: p(1.1808, 15.8125), control2: p(1.367, 17.6022))
        path.addCurve(to: p(8.7513, 21.9892), control1: p(3.5475, 21.3686), control2: p(6.1803, 22.5406))
        path.addCurve(to: p(13.2599, 24), control1: p(9.8948, 23.277), control2: p(11.5377, 24.0097))
        path.addCurve(to: p(19.0317, 19.7942), control1: p(15.8937, 24.0024), control2: p(18.2271, 22.3021))
        path.addCurve(to: p(23.0294, 16.8941), control1: p(20.7194, 19.4475), control2: p(22.176, 18.3908))
        path.addCurve(to: p(22.2819, 9.8212), control1: p(24.3368, 14.6231), control2: p(24.0351, 11.7688))
        path.closeSubpath()
        path.move(to: p(13.2599, 22.4292))
        path.addCurve(to: p(10.3835, 21.3884), control1: p(12.2086, 22.4309), control2: p(11.1903, 22.0624))
        path.addLine(to: p(10.5254, 21.308))
        path.addLine(to: p(15.3037, 18.5498))
        path.addCurve(to: p(15.6964, 17.8685), control1: p(15.5456, 18.4079), control2: p(15.6949, 18.149))
        path.addLine(to: p(15.6964, 11.1316))
        path.addLine(to: p(17.7164, 12.3002))
        path.addCurve(to: p(17.7544, 12.3522), control1: p(17.7367, 12.3105), control2: p(17.7508, 12.3298))
        path.addLine(to: p(17.7544, 17.9348))
        path.addCurve(to: p(13.2599, 22.4292), control1: p(17.7491, 20.4148), control2: p(15.7399, 22.424))
        path.closeSubpath()
        path.move(to: p(3.5992, 18.3038))
        path.addCurve(to: p(3.0646, 15.2901), control1: p(3.072, 17.3934), control2: p(2.8827, 16.3263))
        path.addLine(to: p(3.2066, 15.3753))
        path.addLine(to: p(7.9896, 18.1335))
        path.addCurve(to: p(8.7702, 18.1335), control1: p(8.2306, 18.2749), control2: p(8.5292, 18.2749))
        path.addLine(to: p(14.613, 14.765))
        path.addLine(to: p(14.613, 17.0974))
        path.addCurve(to: p(14.5798, 17.1589), control1: p(14.6119, 17.1219), control2: p(14.5997, 17.1445))
        path.addLine(to: p(9.74, 19.9502))
        path.addCurve(to: p(3.5992, 18.3038), control1: p(7.5893, 21.1891), control2: p(4.8416, 20.4525))
        path.closeSubpath()
        path.move(to: p(2.3408, 7.8956))
        path.addCurve(to: p(4.7063, 5.9228), control1: p(2.8717, 6.9794), control2: p(3.7096, 6.2805))
        path.addLine(to: p(4.7063, 11.6))
        path.addCurve(to: p(5.0942, 12.2765), control1: p(4.7026, 11.8793), control2: p(4.8513, 12.1386))
        path.addLine(to: p(10.9086, 15.6308))
        path.addLine(to: p(8.8885, 16.7993))
        path.addCurve(to: p(8.8175, 16.7993), control1: p(8.8663, 16.8111), control2: p(8.8397, 16.8111))
        path.addLine(to: p(3.9872, 14.0128))
        path.addCurve(to: p(2.3408, 7.872), control1: p(1.8408, 12.7686), control2: p(1.1047, 10.023))
        path.closeSubpath()
        path.move(to: p(18.9371, 11.7514))
        path.addLine(to: p(13.1038, 8.364))
        path.addLine(to: p(15.1192, 7.2))
        path.addCurve(to: p(15.1902, 7.2), control1: p(15.1414, 7.1882), control2: p(15.168, 7.1882))
        path.addLine(to: p(20.0205, 9.9913))
        path.addCurve(to: p(22.2531, 14.258), control1: p(21.5281, 10.8612), control2: p(22.3979, 12.5234))
        path.addCurve(to: p(19.344, 18.0955), control1: p(22.1083, 15.9926), control2: p(20.975, 17.4876))
        path.addLine(to: p(19.344, 12.4183))
        path.addCurve(to: p(18.937, 11.7513), control1: p(19.3355, 12.1397), control2: p(19.1808, 11.8863))
        path.closeSubpath()
        path.move(to: p(20.9478, 8.7283))
        path.addLine(to: p(20.8058, 8.6431))
        path.addLine(to: p(16.0323, 5.8613))
        path.addCurve(to: p(15.2469, 5.8613), control1: p(15.7898, 5.719), control2: p(15.4894, 5.719))
        path.addLine(to: p(9.409, 9.2297))
        path.addLine(to: p(9.409, 6.8974))
        path.addCurve(to: p(9.4374, 6.8359), control1: p(9.4065, 6.8732), control2: p(9.4174, 6.8496))
        path.addLine(to: p(14.2677, 4.0493))
        path.addCurve(to: p(19.0877, 4.2578), control1: p(15.779, 3.1787), control2: p(17.6573, 3.2599))
        path.addCurve(to: p(20.9479, 8.7093), control1: p(20.5182, 5.2556), control2: p(21.2431, 6.9903))
        path.closeSubpath()
        path.move(to: p(8.3065, 12.863))
        path.addLine(to: p(6.2865, 11.6992))
        path.addCurve(to: p(6.2485, 11.6425), control1: p(6.266, 11.6869), control2: p(6.2521, 11.6661))
        path.addLine(to: p(6.2485, 6.0742))
        path.addCurve(to: p(8.8397, 2.0054), control1: p(6.2508, 4.3304), control2: p(7.2605, 2.7449))
        path.addCurve(to: p(13.6242, 2.6205), control1: p(10.419, 1.2659), control2: p(12.2833, 1.5056))
        path.addLine(to: p(13.4822, 2.701))
        path.addLine(to: p(8.704, 5.459))
        path.addCurve(to: p(8.3113, 6.1403), control1: p(8.4621, 5.6009), control2: p(8.3128, 5.8598))
        path.closeSubpath()
        path.move(to: p(9.4041, 10.4976))
        path.addLine(to: p(12.0061, 8.9978))
        path.addLine(to: p(14.613, 10.4976))
        path.addLine(to: p(14.613, 13.497))
        path.addLine(to: p(12.0156, 14.9967))
        path.addLine(to: p(9.4089, 13.497))
        path.closeSubpath()
        return path
    }()

    static let openCode: Path = {
        var path = Path()
        path.move(to: p(22, 24))
        path.addLine(to: p(2, 24))
        path.addLine(to: p(2, 0))
        path.addLine(to: p(22, 0))
        path.closeSubpath()
        path.move(to: p(17, 4.8))
        path.addLine(to: p(7, 4.8))
        path.addLine(to: p(7, 19.2))
        path.addLine(to: p(17, 19.2))
        path.closeSubpath()
        return path
    }()

    static let zai: Path = {
        var path = Path()
        path.addLines([p(12.105, 2), p(9.927, 4.953), p(0.653, 4.953), p(2.83, 2)])
        path.closeSubpath()
        path.addLines([p(23.254, 19.048), p(21.078, 22), p(11.836, 22), p(14.01, 19.048)])
        path.closeSubpath()
        path.addLines([p(24, 2), p(9.264, 22), p(0, 22), p(14.736, 2)])
        path.closeSubpath()
        return path
    }()

    static let antigravity: Path = {
        var path = Path()
        path.move(to: p(21.751, 22.607))
        path.addCurve(to: p(23.259, 21.099), control1: p(23.091, 23.612), control2: p(25.101, 22.942))
        path.addCurve(to: p(12.037, 1), control1: p(17.73, 15.74), control2: p(18.904, 1))
        path.addCurve(to: p(0.815, 21.1), control1: p(5.17, 1), control2: p(6.342, 15.74))
        path.addCurve(to: p(2.322, 22.606), control1: p(-1.195, 23.109), control2: p(0.982, 23.611))
        path.addCurve(to: p(12.037, 12.892), control1: p(7.514, 19.089), control2: p(7.179, 12.892))
        path.addCurve(to: p(21.751, 22.607), control1: p(16.894, 12.892), control2: p(16.559, 19.089))
        path.closeSubpath()
        return path
    }()

    static let deepSeek: Path = {
        var path = Path()
        path.move(to: p(23.748, 4.482))
        path.addCurve(to: p(23.236, 4.716), control1: p(23.494, 4.358), control2: p(23.384, 4.595))
        path.addCurve(to: p(23.099, 4.852), control1: p(23.185, 4.755), control2: p(23.142, 4.806))
        path.addCurve(to: p(21.726, 5.478), control1: p(22.727, 5.249), control2: p(22.293, 5.509))
        path.addCurve(to: p(19.563, 6.326), control1: p(20.897, 5.432), control2: p(20.189, 5.692))
        path.addCurve(to: p(18.316, 4.778), control1: p(19.43, 5.544), control2: p(18.988, 5.078))
        path.addCurve(to: p(17.361, 4.128), control1: p(17.964, 4.622), control2: p(17.608, 4.467))
        path.addCurve(to: p(17.056, 3.354), control1: p(17.189, 3.887), control2: p(17.142, 3.618))
        path.addCurve(to: p(16.763, 3.004), control1: p(17.001, 3.194), control2: p(16.946, 3.031))
        path.addCurve(to: p(16.407, 3.28), control1: p(16.563, 2.973), control2: p(16.485, 3.14))
        path.addCurve(to: p(15.985, 5.12), control1: p(16.094, 3.852), control2: p(15.973, 4.482))
        path.addCurve(to: p(17.823, 8.513), control1: p(16.012, 6.556), control2: p(16.618, 7.7))
        path.addCurve(to: p(17.952, 8.836), control1: p(17.96, 8.606), control2: p(17.995, 8.7))
        path.addCurve(to: p(17.686, 9.669), control1: p(17.87, 9.116), control2: p(17.772, 9.388))
        path.addCurve(to: p(17.357, 9.809), control1: p(17.631, 9.848), control2: p(17.549, 9.886))
        path.addCurve(to: p(15.621, 8.629), control1: p(16.708, 9.53), control2: p(16.119, 9.13))
        path.addCurve(to: p(13.024, 6.171), control1: p(14.764, 7.801), control2: p(13.99, 6.887))
        path.addCurve(to: p(12.335, 5.7), control1: p(12.8, 6.006), control2: p(12.57, 5.849))
        path.addCurve(to: p(12.723, 3.864), control1: p(11.35, 4.743), control2: p(12.465, 3.957))
        path.addCurve(to: p(11.944, 3.436), control1: p(12.993, 3.766), control2: p(12.816, 3.432))
        path.addCurve(to: p(9.257, 4.12), control1: p(11.072, 3.44), control2: p(10.274, 3.731))
        path.addCurve(to: p(8.792, 4.257), control1: p(9.106, 4.178), control2: p(8.95, 4.224))
        path.addCurve(to: p(5.909, 4.155), control1: p(7.842, 4.078), control2: p(6.87, 4.044))
        path.addCurve(to: p(1.412, 6.778), control1: p(4.024, 4.365), control2: p(2.519, 5.257))
        path.addCurve(to: p(0.152, 12.85), control1: p(0.082, 8.606), control2: p(-0.231, 10.684))
        path.addCurve(to: p(3.512, 18.503), control1: p(0.555, 15.134), control2: p(1.721, 17.025))
        path.addCurve(to: p(9.95, 20.643), control1: p(5.37, 20.036), control2: p(7.509, 20.787))
        path.addCurve(to: p(14.944, 18.783), control1: p(11.432, 20.558), control2: p(13.083, 20.359))
        path.addCurve(to: p(16.724, 19.18), control1: p(15.414, 19.017), control2: p(15.906, 19.11))
        path.addCurve(to: p(18.429, 19.052), control1: p(17.354, 19.239), control2: p(17.96, 19.15))
        path.addCurve(to: p(18.848, 18.091), control1: p(19.164, 18.896), control2: p(19.113, 18.215))
        path.addCurve(to: p(16.735, 17.165), control1: p(16.693, 17.087), control2: p(17.166, 17.496))
        path.addCurve(to: p(20.127, 10.162), control1: p(17.831, 15.869), control2: p(19.481, 14.523))
        path.addCurve(to: p(20.127, 9.317), control1: p(20.177, 9.815), control2: p(20.134, 9.597))
        path.addCurve(to: p(20.357, 9.061), control1: p(20.123, 9.147), control2: p(20.162, 9.08))
        path.addCurve(to: p(21.902, 8.586), control1: p(20.898, 9.005), control2: p(21.423, 8.844))
        path.addCurve(to: p(23.995, 5.069), control1: p(23.298, 7.823), control2: p(23.862, 6.571))
        path.addCurve(to: p(23.748, 4.481), control1: p(24.015, 4.839), control2: p(23.991, 4.602))
        path.closeSubpath()
        path.move(to: p(11.581, 18))
        path.addCurve(to: p(8.061, 15.84), control1: p(9.492, 16.358), control2: p(8.479, 15.817))
        path.addCurve(to: p(7.826, 16.603), control1: p(7.669, 15.864), control2: p(7.74, 16.311))
        path.addCurve(to: p(8.197, 17.342), control1: p(7.916, 16.891), control2: p(8.033, 17.089))
        path.addCurve(to: p(8.084, 17.945), control1: p(8.311, 17.509), control2: p(8.389, 17.758))
        path.addCurve(to: p(6.187, 17.778), control1: p(7.411, 18.361), control2: p(6.242, 17.805))
        path.addCurve(to: p(2.886, 14.471), control1: p(4.826, 16.976), control2: p(3.687, 15.918))
        path.addCurve(to: p(1.588, 9.989), control1: p(2.112, 13.078), control2: p(1.662, 11.584))
        path.addCurve(to: p(2.065, 9.397), control1: p(1.568, 9.603), control2: p(1.681, 9.467))
        path.addCurve(to: p(3.594, 9.358), control1: p(2.569, 9.301), control2: p(3.086, 9.287))
        path.addCurve(to: p(9.062, 12.132), control1: p(5.726, 9.67), control2: p(7.54, 10.623))
        path.addCurve(to: p(11.264, 15.023), control1: p(9.93, 12.992), control2: p(10.587, 14.019))
        path.addCurve(to: p(13.744, 17.937), control1: p(11.984, 16.089), control2: p(12.758, 17.105))
        path.addCurve(to: p(14.635, 18.614), control1: p(14.092, 18.229), control2: p(14.369, 18.451))
        path.addCurve(to: p(11.581, 18), control1: p(13.833, 18.704), control2: p(12.495, 18.724))
        path.closeSubpath()
        path.move(to: p(12.581, 11.56))
        path.addCurve(to: p(12.713, 11.307), control1: p(12.581, 11.459), control2: p(12.63, 11.365))
        path.addCurve(to: p(12.996, 11.273), control1: p(12.796, 11.25), control2: p(12.902, 11.237))
        path.addCurve(to: p(13.196, 11.561), control1: p(13.117, 11.317), control2: p(13.198, 11.432))
        path.addCurve(to: p(13.105, 11.779), control1: p(13.196, 11.643), control2: p(13.164, 11.722))
        path.addCurve(to: p(12.886, 11.868), control1: p(13.047, 11.837), control2: p(12.968, 11.869))
        path.addCurve(to: p(12.669, 11.778), control1: p(12.805, 11.868), control2: p(12.726, 11.836))
        path.addCurve(to: p(12.582, 11.56), control1: p(12.612, 11.72), control2: p(12.581, 11.641))
        path.closeSubpath()
        path.move(to: p(15.691, 13.156))
        path.addCurve(to: p(15.101, 13.316), control1: p(15.491, 13.237), control2: p(15.292, 13.307))
        path.addCurve(to: p(14.303, 13.062), control1: p(14.814, 13.326), control2: p(14.532, 13.236))
        path.addCurve(to: p(13.751, 12.304), control1: p(14.029, 12.832), control2: p(13.833, 12.704))
        path.addCurve(to: p(13.767, 11.716), control1: p(13.723, 12.109), control2: p(13.728, 11.91))
        path.addCurve(to: p(13.528, 10.989), control1: p(13.837, 11.389), control2: p(13.759, 11.179))
        path.addCurve(to: p(12.84, 10.79), control1: p(13.341, 10.833), control2: p(13.102, 10.79))
        path.addCurve(to: p(12.586, 10.712), control1: p(12.75, 10.785), control2: p(12.663, 10.758))
        path.addCurve(to: p(12.472, 10.354), control1: p(12.476, 10.658), control2: p(12.386, 10.522))
        path.addCurve(to: p(12.664, 10.144), control1: p(12.5, 10.3), control2: p(12.632, 10.168))
        path.addCurve(to: p(13.81, 10.16), control1: p(13.02, 9.942), control2: p(13.431, 10.008))
        path.addCurve(to: p(14.811, 10.942), control1: p(14.162, 10.304), control2: p(14.428, 10.568))
        path.addCurve(to: p(15.496, 11.856), control1: p(15.202, 11.393), control2: p(15.273, 11.518))
        path.addCurve(to: p(15.941, 12.704), control1: p(15.672, 12.121), control2: p(15.832, 12.393))
        path.addCurve(to: p(15.691, 13.156), control1: p(16.008, 12.899), control2: p(15.922, 13.058))
        path.closeSubpath()
        return path
    }()

    static let kimi: Path = {
        var path = Path()
        path.move(to: p(21.846, 0))
        path.addCurve(to: p(23.769, 1.923), control1: p(22.908, 0), control2: p(23.769, 0.861))
        path.addCurve(to: p(21.846, 3.846), control1: p(23.769, 2.985), control2: p(22.908, 3.846))
        path.addLine(to: p(20.15, 3.846))
        path.addCurve(to: p(19.99, 3.78), control1: p(20.09, 3.846), control2: p(20.032, 3.823))
        path.addCurve(to: p(19.923, 3.62), control1: p(19.947, 3.738), control2: p(19.923, 3.68))
        path.addLine(to: p(19.923, 1.923))
        path.addCurve(to: p(21.846, 0), control1: p(19.923, 0.861), control2: p(20.784, 0))
        path.closeSubpath()
        path.move(to: p(11.065, 11.199))
        path.addLine(to: p(18.322, 3.999))
        path.addCurve(to: p(18.206, 3.589), control1: p(18.459, 3.863), control2: p(18.382, 3.589))
        path.addLine(to: p(14.3, 3.589))
        path.addCurve(to: p(14.183, 3.64), control1: p(14.256, 3.59), control2: p(14.214, 3.608))
        path.addLine(to: p(6.363, 11.396))
        path.addCurve(to: p(6.061, 11.217), control1: p(6.241, 11.516), control2: p(6.061, 11.409))
        path.addLine(to: p(6.061, 3.82))
        path.addCurve(to: p(5.876, 3.59), control1: p(6.061, 3.693), control2: p(5.978, 3.59))
        path.addLine(to: p(3.186, 3.59))
        path.addCurve(to: p(3, 3.82), control1: p(3.083, 3.59), control2: p(3, 3.693))
        path.addLine(to: p(3, 19.77))
        path.addCurve(to: p(3.186, 20), control1: p(3, 19.898), control2: p(3.083, 20))
        path.addLine(to: p(5.876, 20))
        path.addCurve(to: p(6.062, 19.77), control1: p(5.979, 20), control2: p(6.062, 19.898))
        path.addLine(to: p(6.062, 16.52))
        path.addCurve(to: p(6.131, 16.342), control1: p(6.062, 16.451), control2: p(6.087, 16.385))
        path.addLine(to: p(8.555, 13.936))
        path.addCurve(to: p(8.76, 13.913), control1: p(8.608, 13.879), control2: p(8.695, 13.869))
        path.addLine(to: p(15.244, 18.685))
        path.addCurve(to: p(18.697, 19.968), control1: p(16.274, 19.387), control2: p(17.459, 19.827))
        path.addCurve(to: p(18.897, 19.738), control1: p(18.805, 19.98), control2: p(18.897, 19.873))
        path.addLine(to: p(18.897, 16.678))
        path.addCurve(to: p(18.733, 16.451), control1: p(18.897, 16.561), control2: p(18.827, 16.466))
        path.addCurve(to: p(16.706, 15.644), control1: p(18.006, 16.334), control2: p(17.314, 16.058))
        path.addLine(to: p(11.093, 11.58))
        path.addCurve(to: p(11.065, 11.199), control1: p(10.976, 11.502), control2: p(10.961, 11.301))
        path.closeSubpath()
        return path
    }()

    static let openRouter: Path = {
        var path = Path()
        path.move(to: p(18.654, 3.87))
        path.addCurve(to: p(23.741, 8.957), control1: p(21.463, 3.87), control2: p(23.741, 6.148))
        path.addCurve(to: p(18.654, 14.044), control1: p(23.741, 11.766), control2: p(21.463, 14.044))
        path.addLine(to: p(23.7, 19.09))
        path.addCurve(to: p(22.98, 20.827), control1: p(24.34, 19.731), control2: p(23.887, 20.827))
        path.addLine(to: p(8.48, 20.827))
        path.addCurve(to: p(0.001, 12.348), control1: p(3.797, 20.827), control2: p(0.001, 17.031))
        path.addCurve(to: p(8.48, 3.869), control1: p(0.001, 7.665), control2: p(3.797, 3.869))
        path.addLine(to: p(18.655, 3.869))
        path.closeSubpath()
        path.move(to: p(8.479, 7.26))
        path.addCurve(to: p(3.391, 12.348), control1: p(5.669, 7.26), control2: p(3.391, 9.538))
        path.addCurve(to: p(8.479, 17.436), control1: p(3.391, 15.158), control2: p(5.669, 17.436))
        path.addCurve(to: p(13.566, 12.348), control1: p(11.289, 17.436), control2: p(13.566, 15.158))
        path.addCurve(to: p(8.479, 7.261), control1: p(13.566, 9.539), control2: p(11.289, 7.261))
        path.closeSubpath()
        return path
    }()
}
