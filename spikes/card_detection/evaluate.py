"""How well the detector names the cards of a labelled set (YOLO format: images/ + labels/ + data.yaml).

Scored per photo, by card: the set of cards on the photo against the set the detector names (where on the
photo is not scored). Prints precision, recall, the cards missed most and the time per photo; saves the
photos with mistakes, boxed, to --out.

  python evaluate.py --data data/poker-cards --split test --conf 0.4
"""

from __future__ import annotations

import argparse
import collections
import re
from pathlib import Path

import cv2

from cards import CardDetector, draw

RANKS = {"Ace": "A", "King": "K", "Queen": "Q", "Jack": "J"}
SUITS = {"diamonds": "D", "hearts": "H", "spades": "S", "trefoils": "C", "clubs": "C"}


def code_of(name: str) -> str | None:
    """'10 Trefoils', 'A Spades', 'ace of spades', '10H' -> '10C', 'AS', 'AS', '10H'; anything else -> None."""
    if re.fullmatch(r"(10|[2-9AJQK])[CDHS]", name):
        return name
    words = name.replace(" of ", " ").split()
    if len(words) != 2:
        return None
    rank = RANKS.get(words[0].capitalize(), words[0].upper())
    suit = SUITS.get(words[1].lower())
    return rank + suit if suit and re.fullmatch(r"10|[2-9AJQK]", rank) else None


def class_names(data: Path) -> list[str]:
    names, inside = [], False
    for line in (data / "data.yaml").read_text().splitlines():
        if line.startswith("names:"):
            inside = True
            continue
        if inside:
            if not line.startswith("- "):
                break
            names.append(line[2:].strip().strip("'\""))
    return names


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--split", default="test")
    parser.add_argument("--model", type=Path, default=Path(__file__).with_name("model") / "model.onnx")
    parser.add_argument("--conf", type=float, default=0.4)
    parser.add_argument("--tiles", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--out", type=Path, default=Path(__file__).with_name("out") / "evaluate")
    args = parser.parse_args()

    names = class_names(args.data)
    detector = CardDetector(args.model)
    args.out.mkdir(parents=True, exist_ok=True)
    tp = fp = fn = 0
    missed: collections.Counter[str] = collections.Counter()
    wrong: collections.Counter[str] = collections.Counter()
    times = []
    images = sorted((args.data / args.split / "images").glob("*.jpg"))
    for path in images:
        label = args.data / args.split / "labels" / (path.stem + ".txt")
        truth = set()
        for line in label.read_text().splitlines() if label.exists() else []:
            code = code_of(names[int(line.split()[0])])
            if code:
                truth.add(code)
        image = cv2.imread(str(path))
        found, seconds = detector.detect(image, args.conf, args.tiles)
        times.append(seconds)
        named = {c.code for c in found}
        tp += len(truth & named)
        fp += len(named - truth)
        fn += len(truth - named)
        missed.update(truth - named)
        wrong.update(named - truth)
        if truth != named:
            cv2.imwrite(str(args.out / path.name), draw(image, found))

    precision = tp / max(tp + fp, 1)
    recall = tp / max(tp + fn, 1)
    times.sort()
    print(f"photos: {len(images)}, cards on them: {tp + fn}, named: {tp + fp}")
    print(f"precision: {precision:.3f}  recall: {recall:.3f}  (conf {args.conf}, tiles {args.tiles})")
    print(f"time per photo: median {times[len(times) // 2] * 1000:.0f} ms, max {times[-1] * 1000:.0f} ms")
    print("missed most:", ", ".join(f"{c}×{n}" for c, n in missed.most_common(8)) or "none")
    print("named wrongly most:", ", ".join(f"{c}×{n}" for c, n in wrong.most_common(8)) or "none")
    print(f"photos with a mistake, boxed: {args.out}")


if __name__ == "__main__":
    main()
