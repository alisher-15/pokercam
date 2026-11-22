"""Playing-card detector for the spike: an ONNX YOLO model that boxes the corner indices (rank + suit) of
face-up cards, run on the whole frame and, for a large frame, on overlapping tiles; the corners of one card
are merged into one card. CPU only (onnxruntime), no training framework."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

SUITS = {"C": "♣", "D": "♦", "H": "♥", "S": "♠"}


@dataclass
class Box:
    code: str  # "AS", "10H": rank + suit (C D H S)
    conf: float
    x1: float
    y1: float
    x2: float
    y2: float

    @property
    def center(self) -> tuple[float, float]:
        return ((self.x1 + self.x2) / 2, (self.y1 + self.y2) / 2)

    @property
    def diagonal(self) -> float:
        return float(np.hypot(self.x2 - self.x1, self.y2 - self.y1))


def pretty(code: str) -> str:
    return code[:-1] + SUITS.get(code[-1], code[-1])


class CardDetector:
    def __init__(self, model: Path, classes: Path | None = None, size: int = 640, threads: int = 0) -> None:
        options = ort.SessionOptions()
        if threads:
            options.intra_op_num_threads = threads
        self.session = ort.InferenceSession(str(model), options, providers=["CPUExecutionProvider"])
        self.input = self.session.get_inputs()[0].name
        self.size = size
        names = classes or model.with_name("model.classes.json")
        self.names: list[str] = json.loads(Path(names).read_text())

    def _letterbox(self, image: np.ndarray) -> tuple[np.ndarray, float, int, int]:
        h, w = image.shape[:2]
        scale = min(self.size / h, self.size / w)
        nh, nw = round(h * scale), round(w * scale)
        top, left = (self.size - nh) // 2, (self.size - nw) // 2
        canvas = np.full((self.size, self.size, 3), 114, np.uint8)
        canvas[top : top + nh, left : left + nw] = cv2.resize(image, (nw, nh), interpolation=cv2.INTER_LINEAR)
        tensor = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        return tensor, scale, left, top

    def _run(self, image: np.ndarray, conf: float, ox: int = 0, oy: int = 0) -> list[Box]:
        tensor, scale, left, top = self._letterbox(image)
        out = self.session.run(None, {self.input: tensor})[0][0].T  # (anchors, 4 + classes)
        scores = out[:, 4:]
        cls = scores.argmax(1)
        best = scores[np.arange(len(cls)), cls]
        keep = best >= conf
        boxes = []
        for (cx, cy, bw, bh), c, s in zip(out[keep, :4], cls[keep], best[keep], strict=True):
            x1 = (cx - bw / 2 - left) / scale + ox
            y1 = (cy - bh / 2 - top) / scale + oy
            boxes.append(Box(self.names[int(c)], float(s), x1, y1, x1 + bw / scale, y1 + bh / scale))
        return boxes

    @staticmethod
    def _tiles(w: int, h: int, tile: int, overlap: float) -> list[tuple[int, int, int, int]]:
        step = int(tile * (1 - overlap))
        xs = list(range(0, max(w - tile, 0) + 1, step)) or [0]
        ys = list(range(0, max(h - tile, 0) + 1, step)) or [0]
        if xs[-1] + tile < w:
            xs.append(w - tile)
        if ys[-1] + tile < h:
            ys.append(h - tile)
        return [(x, y, min(tile, w), min(tile, h)) for y in ys for x in xs]

    def corners(self, image: np.ndarray, conf: float = 0.4, tiles: str = "auto", tile: int = 0) -> list[Box]:
        """Every corner index found: the whole frame, plus overlapping tiles when the frame is much larger than
        the model's input (on a 1080p table shot the indices are a few dozen pixels). `tile`: the tile side in
        pixels (0: half the frame's short side); smaller tiles find smaller cards, at more time per frame."""
        h, w = image.shape[:2]
        found = self._run(image, conf)
        if tiles == "on" or (tiles == "auto" and max(w, h) > 1.5 * self.size):
            tile = min(tile or max(self.size, min(w, h) // 2), min(w, h))
            for x, y, tw, th in self._tiles(w, h, tile, 0.25):
                found += self._run(image[y : y + th, x : x + tw], conf, x, y)
        return self._nms(found)

    @staticmethod
    def _nms(boxes: list[Box], iou: float = 0.5) -> list[Box]:
        if not boxes:
            return []
        rects = [[b.x1, b.y1, b.x2 - b.x1, b.y2 - b.y1] for b in boxes]
        codes = sorted({b.code for b in boxes})
        ids = [codes.index(b.code) for b in boxes]
        keep = cv2.dnn.NMSBoxesBatched(rects, [b.conf for b in boxes], ids, 0.0, iou)
        return [boxes[int(i)] for i in np.array(keep).flatten()]

    @staticmethod
    def cards(corners: list[Box], reach: float = 7.0) -> list[Box]:
        """One card per group of same-code corners lying within `reach` corner diagonals of each other."""
        result = []
        for code in sorted({b.code for b in corners}):
            group = [b for b in corners if b.code == code]
            parent = list(range(len(group)))
            for i, a in enumerate(group):
                for j in range(i + 1, len(group)):
                    b = group[j]
                    limit = reach * max(a.diagonal, b.diagonal)
                    if np.hypot(a.center[0] - b.center[0], a.center[1] - b.center[1]) <= limit:
                        parent[_root(parent, i)] = _root(parent, j)
            clusters: dict[int, list[Box]] = {}
            for i, b in enumerate(group):
                clusters.setdefault(_root(parent, i), []).append(b)
            for members in clusters.values():
                result.append(
                    Box(
                        code,
                        max(m.conf for m in members),
                        min(m.x1 for m in members),
                        min(m.y1 for m in members),
                        max(m.x2 for m in members),
                        max(m.y2 for m in members),
                    )
                )
        return sorted(result, key=lambda b: (b.x1, b.y1))

    def detect(
        self, image: np.ndarray, conf: float = 0.4, tiles: str = "auto", tile: int = 0
    ) -> tuple[list[Box], float]:
        started = time.perf_counter()
        found = self.cards(self.corners(image, conf, tiles, tile))
        return found, time.perf_counter() - started


def _root(parent: list[int], i: int) -> int:
    """Union-find: the group of item i (with path halving)."""
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i


def draw(image: np.ndarray, cards: list[Box]) -> np.ndarray:
    out = image.copy()
    for c in cards:
        p1, p2 = (int(c.x1), int(c.y1)), (int(c.x2), int(c.y2))
        cv2.rectangle(out, p1, p2, (0, 220, 255), 2)
        label = f"{c.code} {c.conf:.2f}"
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
        cv2.rectangle(out, (p1[0], p1[1] - th - 8), (p1[0] + tw + 6, p1[1]), (0, 220, 255), -1)
        cv2.putText(out, label, (p1[0] + 3, p1[1] - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 2)
    return out
