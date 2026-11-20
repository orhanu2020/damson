import SwiftUI
import AppKit

/// Colours and small layout helpers for Damson's chat look: deep green, warm paper, soft borders.
enum Theme {
    static let green = Color(red: 0.17, green: 0.27, blue: 0.22)
    static let olive = Color(red: 0.45, green: 0.38, blue: 0.12)
    static let onlineGreen = Color(red: 0.20, green: 0.55, blue: 0.35)

    static let chatBackground = dynamic(light: (0.98, 0.98, 0.96), dark: (0.11, 0.12, 0.11))
    static let card = dynamic(light: (1.0, 1.0, 1.0), dark: (0.17, 0.18, 0.17))
    static let stroke = dynamic(light: (0.85, 0.86, 0.83), dark: (0.29, 0.30, 0.29))
    static let chip = dynamic(light: (0.95, 0.96, 0.94), dark: (0.15, 0.16, 0.15))

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        let color = NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        return Color(nsColor: color)
    }
}

/// Lays children out left to right and wraps to a new row when the line is full (used for the suggestion chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
