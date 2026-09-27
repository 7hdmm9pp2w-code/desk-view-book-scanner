import Testing
import Foundation
@testable import BookScannerKit

@Suite struct PageSequenceTests {
    func r(_ n: Int) -> ClosedRange<Int> { n...n }

    @Test func consecutivePagesAreFine() {
        #expect(PageSequence.check([r(1), r(2), nil, r(4), r(5)]).isEmpty)
    }

    @Test func gapDuplicateAndOrder() {
        let issues = PageSequence.check([r(10), r(11), r(14), r(15), r(15), r(16), r(17)])
        #expect(issues == [2: .missing(from: 12, to: 13), 4: .duplicate(scan: 4)])
    }

    @Test func pagesScannedLaterCloseTheGap() {
        // 12 und 13 kommen nachträglich: Die Lücke ist zu, die beiden stehen falsch.
        let issues = PageSequence.check([r(10), r(11), r(14), r(15), r(12), r(13), r(16)])
        #expect(issues == [4: .outOfOrder(previous: 15)])
    }

    @Test func outOfOrderPage() {
        let issues = PageSequence.check([r(20), r(21), r(23), r(22)])
        #expect(issues == [3: .outOfOrder(previous: 23)])
    }

    @Test func misreadNumberIsIgnored() {
        // „36" statt „38": Die nächste Seite passt wieder zur vorherigen.
        #expect(PageSequence.check([r(36), r(37), r(86), r(39), r(40)]).isEmpty)
    }

    @Test func unconfirmedHugeJumpIsIgnoredAtTheEnd() {
        #expect(PageSequence.check([r(5), r(6), r(600)]).isEmpty)
        #expect(PageSequence.check([r(5), r(6), r(10)])[2] == .missing(from: 7, to: 9))
    }

    @Test func spreadsCountTwoPagesPerScan() {
        #expect(PageSequence.check([10...11, 12...13, nil, 16...17]).isEmpty)
        #expect(PageSequence.check([10...11, 12...13, 16...17])[2] == .missing(from: 14, to: 15))
    }

    @Test func seriesNumberOnTheTitlePageIsNoAnchor() {
        // „insel taschenbuch 1207“ oben auf der Titelseite, danach die echte Folge.
        #expect(PageSequence.check([r(1207), nil, r(5), r(6), r(7)]).isEmpty)
        // Beim Scannen: Seite 5 ist gerade erst da, die 6 fehlt noch.
        #expect(PageSequence.check([r(1207), nil, r(5)]).isEmpty)
        // Echt vertauscht bleibt vertauscht: Die kleinere Zahl hat keine Folge hinter sich.
        #expect(PageSequence.check([r(20), r(21), r(23), r(22)]) == [3: .outOfOrder(previous: 23)])
    }

    func line(_ text: String, x: CGFloat = 0.5, y: CGFloat) -> RecognizedLine {
        RecognizedLine(text: text, confidence: 1, box: CGRect(x: x - 0.1, y: y - 0.01, width: 0.2, height: 0.02))
    }

    func text(_ lines: [RecognizedLine]) -> PageText {
        PageText(pageID: UUID(), pixelWidth: 100, pixelHeight: 100, languages: [], lines: lines)
    }

    @Test func readsPrintedNumbers() {
        let body = (0..<10).map { line("Fließtext mit vielen Wörtern in Zeile \($0)", y: 0.8 - CGFloat($0) * 0.05) }
        #expect(PageSequence.printedNumbers(in: text(body + [line("– 42 –", y: 0.05)])) == 42...42)
        #expect(PageSequence.printedNumbers(in: text([line("24 Einleitung", y: 0.95)] + body)) == 24...24)
        // Doppelseite: links 24, rechts 25.
        #expect(PageSequence.printedNumbers(in: text(body + [line("24", x: 0.2, y: 0.05), line("25", x: 0.8, y: 0.05)])) == 24...25)
        // Fußnote unten mit Zahl vorn ist keine Seitenzahl.
        #expect(PageSequence.printedNumbers(in: text(body + [line("3 Vgl. Müller 1998", y: 0.05)])) == nil)
        // Zahl mitten im Text ebenso wenig.
        #expect(PageSequence.printedNumbers(in: text(body + [line("1990", y: 0.5)])) == nil)
    }
}
