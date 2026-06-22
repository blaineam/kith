import SwiftUI

/// Instagram-style story captions: pick a color, tap through typography styles, and
/// toggle between "text color (with glow)" and "color as a highlight behind the text".
/// The choice is encoded into the story body so the viewer renders it identically.
enum StoryCaptions {
    static let colors: [Color] = [
        .white, .black, HavenTheme.pink, HavenTheme.violet, HavenTheme.amber,
        .red, .orange, .green, .blue, .cyan, .yellow, .mint,
    ]
    /// Typography choices (design + weight); the point size is scaled by `Spec.size`.
    static let fontStyles: [(design: Font.Design, weight: Font.Weight)] = [
        (.default, .bold), (.serif, .bold), (.rounded, .heavy), (.monospaced, .bold), (.default, .black),
    ]
    static let minSize = 0.6
    static let maxSize = 1.9

    struct Spec: Equatable {
        var color = 0
        var font = 0
        var highlight = false
        /// Normalized caption position (0…1) so the viewer renders it where the author
        /// dragged it. Defaults to centred.
        var x = 0.5
        var y = 0.5
        /// Caption size scale the author sets while composing (base 28pt × size).
        var size = 1.0
        mutating func cycleFont() { font = (font + 1) % fontStyles.count }
    }

    static func textColor(_ s: Spec) -> Color { s.highlight ? contrast(s.color) : colors[idx(s.color)] }
    static func bgColor(_ s: Spec) -> Color? { s.highlight ? colors[idx(s.color)] : nil }
    static func font(_ s: Spec) -> Font {
        let style = fontStyles[min(max(0, s.font), fontStyles.count - 1)]
        return .system(size: 28 * s.size, weight: style.weight, design: style.design)
    }

    private static func idx(_ i: Int) -> Int { min(max(0, i), colors.count - 1) }
    private static func contrast(_ i: Int) -> Color {
        // Light highlight colors get dark text; everything else gets white.
        [0, 9, 10, 11].contains(idx(i)) ? .black : .white   // white, cyan, yellow, mint
    }

    static func encode(_ caption: String, _ s: Spec) -> String {
        let t = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        let extra = String(format: "%.3f,%.3f,%.3f", s.x, s.y, s.size)
        return "\u{1}\(s.color),\(s.font),\(s.highlight ? 1 : 0),\(extra)\u{1}\(t)"
    }
    static func decode(_ body: String) -> (text: String, spec: Spec) {
        if body.hasPrefix("\u{1}") {
            let parts = body.dropFirst().split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                let n = parts[0].split(separator: ",")
                if n.count >= 3, let c = Int(n[0]), let f = Int(n[1]), let h = Int(n[2]) {
                    var spec = Spec(color: c, font: f, highlight: h == 1)
                    if n.count >= 5, let x = Double(n[3]), let y = Double(n[4]) { spec.x = x; spec.y = y }
                    if n.count >= 6, let sz = Double(n[5]) { spec.size = sz }
                    return (String(parts[1]), spec)
                }
            }
        }
        return (body, Spec())
    }
}

/// Renders a caption in its chosen style.
struct StyledCaption: View {
    let text: String
    let spec: StoryCaptions.Spec
    var body: some View {
        let bg = StoryCaptions.bgColor(spec)
        Text(text.isEmpty ? " " : text)
            .font(StoryCaptions.font(spec))
            .foregroundStyle(StoryCaptions.textColor(spec))
            .multilineTextAlignment(.center)
            .padding(.horizontal, bg == nil ? 0 : 14)
            .padding(.vertical, bg == nil ? 0 : 8)
            .background { if let bg { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg) } }
            .shadow(color: bg == nil ? .black.opacity(0.55) : .clear, radius: 8)   // glow on plain text
    }
}

/// A row of color dots for the composer.
struct CaptionColorRow: View {
    @Binding var spec: StoryCaptions.Spec
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(StoryCaptions.colors.enumerated()), id: \.offset) { i, c in
                    Button { spec.color = i } label: {
                        Circle().fill(c).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.white, lineWidth: spec.color == i ? 3 : 1))
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
