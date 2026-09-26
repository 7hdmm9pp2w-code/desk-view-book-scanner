#!/usr/bin/env python3
"""Zeilenhöhen und Konfidenzen der OCR-Ergebnisse einer Session.

    python3 scripts/ocr_stats.py                 # neueste Session unter ~/Documents/Buchscans
    python3 scripts/ocr_stats.py <Session-Ordner>

Faustregel: Vision liest Fließtext ab etwa 20 px Zeilenhöhe zuverlässig,
unter 12 px wird es Raten.
"""
import glob
import json
import os
import statistics
import sys


def box_height(box):
    # CGRect kodiert als [[x, y], [w, h]]
    return box[1][1] if isinstance(box[0], list) else box[3]


def main():
    root = os.path.expanduser("~/Documents/Buchscans")
    if len(sys.argv) > 1:
        session = sys.argv[1]
    else:
        try:
            names = os.listdir(root)
        except PermissionError:
            sys.exit(
                f"Kein Zugriff auf {root}. Das Terminal braucht die Freigabe für den Ordner "
                "„Dokumente“ (Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner), "
                "oder das Skript in Terminal.app starten."
            )
        except FileNotFoundError:
            sys.exit(f"Ordner {root} gibt es nicht; noch keine Session angelegt?")
        sessions = [os.path.join(root, n) for n in names if os.path.isfile(os.path.join(root, n, "session.json"))]
        if not sessions:
            sys.exit(f"Keine Session unter {root}")
        session = max(sessions, key=os.path.getmtime)
    print(f"Session: {session}")
    files = sorted(glob.glob(os.path.join(session, "OCR", "*.json")))
    if not files:
        sys.exit("Keine OCR-Dateien (noch nicht erkannt?)")
    for path in files:
        text = json.load(open(path))
        height, width = text["pixelHeight"], text["pixelWidth"]
        lines = text["lines"]
        print(f"\n{os.path.basename(path)}: {width} x {height} px, {len(lines)} Zeilen")
        if not lines:
            continue
        heights = sorted(box_height(l["box"]) * height for l in lines)
        confidences = [l["confidence"] for l in lines]
        print(f"  Zeilenhöhe px: min {heights[0]:.0f}  median {statistics.median(heights):.0f}  max {heights[-1]:.0f}")
        print(f"  Konfidenz: median {statistics.median(confidences):.2f}, unter 0.5: {sum(c < 0.5 for c in confidences)} Zeilen")
        for l in lines[:40]:
            h = box_height(l["box"]) * height
            print(f"  {h:5.0f} px  {l['confidence']:.2f}  {l['text'][:80]}")


if __name__ == "__main__":
    main()
