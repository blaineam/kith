import SwiftUI

/// Haven's brand, ported to the wrist — same sunset palette (violet → pink → amber) as the
/// iOS app's `HavenTheme`, tuned for the small always-dark watch screen.
enum WTheme {
    static let violet = Color(red: 0.486, green: 0.227, blue: 0.929) // #7C3AED
    static let pink   = Color(red: 0.925, green: 0.282, blue: 0.600) // #EC4899
    static let amber  = Color(red: 0.961, green: 0.620, blue: 0.043) // #F59E0B

    static let brand = LinearGradient(colors: [violet, pink, amber],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandH = LinearGradient(colors: [violet, pink, amber],
                                       startPoint: .leading, endPoint: .trailing)

    /// A stable two-stop gradient derived from a name, so each person gets a consistent,
    /// on-brand avatar without storing anything.
    static func avatar(for seed: String) -> LinearGradient {
        let palette: [Color] = [violet, pink, amber, .init(red: 0.20, green: 0.65, blue: 0.86)]
        let h = abs(seed.hashValue)
        let a = palette[h % palette.count]
        let b = palette[(h / 7 + 1) % palette.count]
        return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Black base with two soft brand glows — the wrist version of `HavenBackground`.
struct WatchBackground: View {
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [WTheme.pink.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.92, y: -0.02), startRadius: 0, endRadius: 210)
            RadialGradient(colors: [WTheme.violet.opacity(0.18), .clear],
                           center: UnitPoint(x: 0.02, y: 1.0), startRadius: 0, endRadius: 230)
        }
        .ignoresSafeArea()
    }
}

/// Round avatar: initials for a DM, the Haven sparkle for a circle, on a per-name gradient.
struct WatchAvatar: View {
    let title: String
    let isDM: Bool
    var size: CGFloat = 32

    private var initials: String {
        let parts = title.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(WTheme.avatar(for: title))
            if isDM {
                Text(initials)
                    .font(.system(size: size * 0.40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: WTheme.pink.opacity(0.25), radius: 3, y: 1)
    }
}

/// The branded wordmark used as the list header.
struct WatchBrandHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            ConstellationGlyph()
                .frame(width: 18, height: 18)
            Text("Haven")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(WTheme.brandH)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }
}

/// A tiny constellation mark (mirrors the iOS `ConstellationMark`, simplified for the wrist).
struct ConstellationGlyph: View {
    private let nodes: [CGPoint] = [
        CGPoint(x: 50, y: 53), CGPoint(x: 50, y: 22), CGPoint(x: 22, y: 46),
        CGPoint(x: 78, y: 46), CGPoint(x: 34, y: 78), CGPoint(x: 66, y: 78),
    ]
    private let edges = [(0,1),(0,2),(0,3),(0,4),(0,5)]
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 100
            ZStack {
                Path { p in
                    for (a, b) in edges { p.move(to: pt(nodes[a], s)); p.addLine(to: pt(nodes[b], s)) }
                }
                .stroke(WTheme.pink.opacity(0.7), lineWidth: 2 * s)
                ForEach(nodes.indices, id: \.self) { i in
                    let r = (i == 0 ? 8.0 : 5.5) * s
                    Circle().fill(i == 0 ? AnyShapeStyle(WTheme.brandH) : AnyShapeStyle(Color.white))
                        .frame(width: r * 2, height: r * 2).position(pt(nodes[i], s))
                }
            }
        }
    }
    private func pt(_ p: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
}

/// Card chrome for list rows — subtle elevated surface with a hairline border.
struct WatchCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}
extension View {
    func watchCard() -> some View { modifier(WatchCard()) }
}

/// Brand-gradient capsule button (Reply / Send).
struct WatchBrandButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(WTheme.brandH, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .shadow(color: WTheme.pink.opacity(0.4), radius: 6, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
