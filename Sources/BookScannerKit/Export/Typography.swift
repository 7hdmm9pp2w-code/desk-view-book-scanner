import Foundation
import CoreGraphics

/// Zeilenhöhe und Zeilenabstand als Median über alle Seiten.
struct Typography {
    var medianHeight: CGFloat?
    var medianCharWidth: CGFloat?
    var pitch: CGFloat?

    init(pages: [PageText], minimumLines: Int) {
        var heights: [CGFloat] = []
        var charWidths: [CGFloat] = []
        var gaps: [CGFloat] = []
        for page in pages {
            let lines = page.lines.filter { !$0.text.isEmpty && $0.confidence >= 0.3 }
            heights.append(contentsOf: lines.map(\.box.height))
            charWidths.append(contentsOf: lines.filter { $0.text.count >= 8 }.map(\.charWidth))
            for (a, b) in zip(lines, lines.dropFirst()) {
                let gap = a.box.midY - b.box.midY
                if gap > 0 { gaps.append(gap) }
            }
        }
        guard heights.count >= minimumLines else { return }
        medianHeight = heights.sorted()[heights.count / 2]
        if !charWidths.isEmpty { medianCharWidth = charWidths.sorted()[charWidths.count / 2] }
        if !gaps.isEmpty { pitch = gaps.sorted()[gaps.count / 2] }
    }
}
