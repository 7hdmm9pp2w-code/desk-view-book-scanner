import Testing
import Foundation
@testable import BookScannerKit

@Suite struct PageTurnJudgeTests {
    /// Weißes Blatt mit zufälligen dunklen Wortblöcken, reproduzierbar über `seed`.
    func page(seed: UInt64, width: Int = 320, height: Int = 240) -> GrayFrame {
        var state = seed
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        var pixels = [UInt8](repeating: 235, count: width * height)
        for y in stride(from: 20, to: height - 20, by: 8) {
            var x = 20
            while x < width - 20 {
                let length = Int(next() % 24) + 6
                for yy in y..<(y + 4) { for xx in x..<min(x + length, width - 20) { pixels[yy * width + xx] = 40 } }
                x += length + Int(next() % 8) + 4
            }
        }
        return GrayFrame(pixels: pixels, width: width)
    }

    func shifted(_ frame: GrayFrame, dx: Int, dy: Int) -> GrayFrame {
        var out = [UInt8](repeating: 235, count: frame.pixels.count)
        let w = frame.width, h = frame.height
        for y in 0..<h { for x in 0..<w {
            let sx = x - dx, sy = y - dy
            if sx >= 0, sx < w, sy >= 0, sy < h { out[y * w + x] = frame.pixels[sy * w + sx] }
        } }
        return GrayFrame(pixels: out, width: w)
    }

    @Test func differentPageIsNew() {
        let judge = PageTurnJudge()
        #expect(judge.changedShare(page(seed: 1), page(seed: 2)) > 0.6)
    }

    @Test func shiftedDarkerOrHandCoveredPageIsTheSame() {
        let judge = PageTurnJudge()
        let a = page(seed: 1)
        #expect(judge.changedShare(a, shifted(a, dx: 3, dy: -2)) < 0.1)
        let darker = GrayFrame(pixels: a.pixels.map { UInt8(Double($0) * 0.6) }, width: a.width)
        #expect(judge.changedShare(a, darker) < 0.1)
        var hand = a
        for y in 150..<240 { for x in 250..<320 { hand.pixels[y * a.width + x] = 180 } }
        #expect(judge.changedShare(a, hand) < judge.changedTileShare)
    }

    @Test func wordsDecideWhenThereIsText() {
        let old = """
            Die Grundlagen der Kameraführung werden im folgenden Kapitel ausführlich erläutert, zusammen \
            mit Beispielen aus der Praxis und vielen Übungen für Anfänger. Wer diese Übungen regelmäßig \
            wiederholt, entwickelt schnell ein Gefühl für Bildausschnitt, Perspektive und Bewegung.
            """
        let new = """
            Belichtungszeit, Blende und Empfindlichkeit bestimmen gemeinsam die Helligkeit eines Fotos; \
            wer eine davon verändert, muss eine andere ausgleichen, sonst kippt das Ergebnis. Dieses \
            Dreieck gehört zum Handwerk jeder Fotografin und jedes Fotografen.
            """
        let frame = page(seed: 1)
        var judge = PageTurnJudge()
        judge.remember(PageSnapshot(frame: frame, lines: [old]))
        // Gleiches Bild, anderer Text: neue Seite (Pixel allein hätten das übersehen).
        #expect(judge.isNewPage(PageSnapshot(frame: frame, lines: [new])))
        // Halb verdeckt: weniger Wörter, aber fast nur alte, trotz ganz anderem Bild.
        let half = old.split(separator: " ").prefix(28).joined(separator: " ")
        #expect(!judge.isNewPage(PageSnapshot(frame: page(seed: 9), lines: [half])))
    }

    /// Wörter aus zwei Erkennungen derselben Seite und einer anderen, aus einem Mitschnitt.
    @Test func misreadWordsStillMatch() {
        let first = ["erlaubten", "lorenzo", "sohn", "piero", "medici", "welche", "gunst", "eines", "fursten", "erwerben", "trachten", "pflegen"]
        let second = ["erlandten", "lorcazo", "sohn", "piero", "meilici", "welcte", "ganst", "eines", "färsten", "erwerhen", "trachten", "pflegen"]
        let other = ["denn", "wolle", "sache", "sich", "selbst", "ehre", "aber", "mannigfaltigkeit", "stoffes", "ernst", "gegenstandes", "arten"]
        #expect(PageTurnJudge.sharedWordShare(first, second) >= PageTurnJudge().sameTextShare)
        #expect(PageTurnJudge.sharedWordShare(first, other) < PageTurnJudge().sameTextShare)
        #expect(PageTurnJudge.editDistance(Array("fürsten"), Array("fursten"), limit: 2) == 1)
    }

    struct Recording: Decodable {
        struct Shot: Decodable {
            var aufnahme: String
            var art: String
            var doppelseite: Int
            var woerter: [String]
        }
        var aufnahmen: [Shot]
    }

    /// Mitschnitt über einem Taschenbuch, abgespielt: Jede ruhige Aufnahme ist eine neue
    /// Doppelseite, außer der zweiten von Doppelseite 6 (davor nicht ausgelöst). Mit dem
    /// alten Vergleich galten vier davon als schon erfasst, darunter volle Textseiten mit
    /// 300 Wörtern und ein Zwischentitel mit 32 Wörtern nach einer vollen Seite.
    @Test func recordedPageTurnsAreNewPages() throws {
        let url = try #require(Bundle.module.url(forResource: "umblaettern-mitschnitt", withExtension: "json", subdirectory: "Fixtures"))
        let shots = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)).aufnahmen
        var judge = PageTurnJudge()
        var captured: Set<Int> = []
        for shot in shots {
            // Kacheln je Doppelseite verschieden, damit nur Seiten mit wenig Text an ihnen hängen.
            let snapshot = PageSnapshot(frame: page(seed: UInt64(shot.doppelseite)), words: shot.woerter)
            if shot.art == "erfasst" {
                judge.remember(snapshot)
                captured.insert(shot.doppelseite)
            } else {
                #expect(judge.isNewPage(snapshot) == !captured.contains(shot.doppelseite), "\(shot.aufnahme)")
            }
        }
        // Dieselbe Seite zweimal gelesen: Ab 40 Wörtern erkennt der Text sie wieder.
        for (ruhig, erfasst) in zip(shots, shots.dropFirst()) where ruhig.art == "ruhig" && erfasst.art == "erfasst"
            && ruhig.doppelseite == erfasst.doppelseite && min(ruhig.woerter.count, erfasst.woerter.count) >= 40 {
            #expect(PageTurnJudge.sharedWordShare(ruhig.woerter, erfasst.woerter) >= PageTurnJudge().sameTextShare, "\(erfasst.aufnahme)")
        }
    }

    @Test func fewForeignWordsMakeANewPage() {
        let frame = page(seed: 1)
        let text = PageSnapshot(frame: frame, lines: ["Wer diese Übungen regelmäßig wiederholt, entwickelt schnell ein Gefühl für Bildausschnitt, Perspektive, Bewegung und Licht."])
        let title = PageSnapshot(frame: frame, lines: ["Der Fürst", "Zueignung an Lorenzo"])
        let titleAgain = PageSnapshot(frame: frame, lines: ["Der Fürst", "Zueignung an"])
        // Zwischentitel nach einer Textseite: Kacheln gleich (Hände, Buchrand), Wörter fremd.
        #expect(!PageTurnJudge().isSamePage(text, title))
        // Derselbe Zwischentitel, einmal schlechter gelesen: Kacheln entscheiden, gleich.
        #expect(PageTurnJudge().isSamePage(title, titleAgain))
    }

    @Test func turningBackIsNotANewPage() {
        var judge = PageTurnJudge()
        let a = PageSnapshot(frame: page(seed: 1), words: [])
        let b = PageSnapshot(frame: page(seed: 2), words: [])
        #expect(judge.isNewPage(a))
        judge.remember(a)
        #expect(judge.isNewPage(b))
        judge.remember(b)
        #expect(!judge.isNewPage(PageSnapshot(frame: shifted(page(seed: 1), dx: 1, dy: 1), words: [])))
        // Dieselbe Seite noch einmal gemerkt, verdrängt keine ältere.
        judge.remember(b)
        #expect(judge.recent.count == 2)
    }

    @Test func blankPagesAreTheSame() {
        let blank = GrayFrame(pixels: [UInt8](repeating: 230, count: 320 * 240), width: 320)
        #expect(PageTurnJudge().changedShare(blank, blank) == 0)
    }
}
