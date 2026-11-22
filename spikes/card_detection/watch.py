"""Names the face-up cards on a table: live from the server's recording of a table, or from a video or photos.

  python watch.py --server http://IP:8000 --key CLUB-KEY [--table 1]   live, a few seconds behind the camera
  python watch.py --video table.mp4                                     a recording -> out/table-cards.mp4
  python watch.py --image photo.jpg [more.jpg ...]                      photos -> out/*-cards.jpg

Live, it reads the same recording the PC's rewind plays (media-server's /dvr playlist), so the camera must send
H.264 (the reference phone): with VP8 the server records nothing. It signs in like a club PC, with the client's
activation key; in the admin panel it shows as a computer named "Card recognition test".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from urllib.parse import urljoin, urlsplit

# The first segment fetched may start mid-GOP: FFmpeg's warnings about it are noise here.
os.environ.setdefault("OPENCV_FFMPEG_LOGLEVEL", "-8")

import cv2

from cards import CardDetector, draw, pretty

HERE = Path(__file__).parent


def call(url: str, body: dict | None = None, token: str | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method="POST" if body is not None else "GET")
    request.add_header("content-type", "application/json")
    if token:
        request.add_header("authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        sys.exit(f"{url}: HTTP {e.code} {detail}")


def fetch(url: str, token: str) -> bytes | None:
    request = urllib.request.Request(url, headers={"authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


class Club:
    """The club's server as a PC sees it: activation once (kept in out/session.json), then tokens."""

    def __init__(self, server: str, key: str) -> None:
        self.api = server.rstrip("/") + "/api/v1"
        session = HERE / "out" / "session.json"
        saved = json.loads(session.read_text()) if session.exists() else {}
        if saved.get("server") == server and saved.get("key") == key:
            self.refresh = saved["refresh_token"]
        else:
            machine = "card-test-" + hashlib.sha1(platform.node().encode()).hexdigest()[:12]
            answer = call(
                f"{self.api}/viewer/activate",
                {"activation_key": key, "machine_id": machine, "name": "Card recognition test"},
            )
            self.refresh = answer["refresh_token"]
            session.parent.mkdir(exist_ok=True)
            session.write_text(json.dumps({"server": server, "key": key, "refresh_token": self.refresh}))

    def token(self, table_id: str | None = None) -> dict:
        body = {"refresh_token": self.refresh} | ({"table_id": table_id} if table_id else {})
        return call(f"{self.api}/auth/token", body)

    def table(self, number: int | None) -> dict:
        tables = call(f"{self.api}/tables", token=self.token()["access_token"])["tables"]
        if not tables:
            sys.exit("the client has no tables")
        if number is None:
            return next((t for t in tables if t.get("camera_online")), tables[0])
        for t in tables:
            if t["number"] == number:
                return t
        sys.exit(f"no table {number}; tables: {[t['number'] for t in tables]}")


def say(stamp: str, cards: list, seconds: float) -> None:
    names = ", ".join(f"{pretty(c.code)} {c.conf:.2f}" for c in cards) or "—"
    print(f"{stamp}  {names}   ({seconds * 1000:.0f} ms)", flush=True)


def live(args: argparse.Namespace, detector: CardDetector) -> None:
    club = Club(args.server, args.key)
    table = club.table(args.table)
    print(f"table {table['number']} ({table['name']}), camera {'on air' if table.get('camera_online') else 'off'}")
    out = HERE / "out" / "live"
    out.mkdir(parents=True, exist_ok=True)
    seen: set[str] = set()
    last: set[str] | None = None
    token, got_at = None, 0.0
    waited = False
    while True:
        if token is None or time.time() - got_at > 1800:
            answer = club.token(table["id"])
            token, got_at = answer["access_token"], time.time()
            media = urlsplit(answer["media_url"])
            base = f"{'https' if media.scheme == 'wss' else 'http'}://{media.netloc}"
            playlist = f"{base}/dvr/{table['id']}/index.m3u8"
        text = fetch(playlist, token)
        if text is None:
            if not waited:
                print("no recording for this table yet: is the camera on air, with H.264? waiting...")
                waited = True
            time.sleep(2)
            continue
        stamp = ""
        segments = []
        for line in text.decode().splitlines():
            if line.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
                stamp = line.split(":", 1)[1]
            elif line and not line.startswith("#"):
                segments.append((urljoin(playlist, line), stamp))
        fresh = [s for s in segments if s[0] not in seen]
        if not seen:
            fresh = fresh[-1:]  # start at the live edge, not 10 minutes back
        for url, stamp in fresh[-2:]:
            seen.add(url)
            data = fetch(url, token)
            if data is None:
                continue
            with tempfile.NamedTemporaryFile(suffix=".ts") as f:
                f.write(data)
                f.flush()
                capture = cv2.VideoCapture(f.name)
                ok, frame = capture.read()
                capture.release()
            if not ok:
                continue
            cards, seconds = detector.detect(frame, args.conf, args.tiles, args.tile)
            clock = datetime.fromisoformat(stamp).astimezone().strftime("%H:%M:%S") if stamp else "--:--:--"
            say(clock, cards, seconds)
            now = {c.code for c in cards}
            if now != last:
                cv2.imwrite(str(out / f"{clock.replace(':', '')}.jpg"), draw(frame, cards))
                last = now
        seen.update(u for u, _ in segments)
        time.sleep(1)


def video(args: argparse.Namespace, detector: CardDetector) -> None:
    capture = cv2.VideoCapture(str(args.video))
    fps = capture.get(cv2.CAP_PROP_FPS) or 25
    every = max(1, round(fps / args.fps))
    out = HERE / "out" / f"{args.video.stem}-cards.mp4"
    out.parent.mkdir(exist_ok=True)
    writer = None
    index = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        if index % every == 0:
            cards, seconds = detector.detect(frame, args.conf, args.tiles, args.tile)
            say(f"{index / fps:7.1f} s", cards, seconds)
            boxed = draw(frame, cards)
            if writer is None:
                h, w = frame.shape[:2]
                writer = cv2.VideoWriter(str(out), cv2.VideoWriter_fourcc(*"mp4v"), args.fps, (w, h))
            writer.write(boxed)
        index += 1
    if writer:
        writer.release()
        print(f"boxed video: {out}")


def images(args: argparse.Namespace, detector: CardDetector) -> None:
    out = HERE / "out"
    out.mkdir(exist_ok=True)
    for path in args.image:
        frame = cv2.imread(str(path))
        if frame is None:
            print(f"{path}: not an image")
            continue
        cards, seconds = detector.detect(frame, args.conf, args.tiles, args.tile)
        say(path.name, cards, seconds)
        cv2.imwrite(str(out / f"{path.stem}-cards.jpg"), draw(frame, cards))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--server", help="the club's server, e.g. http://203.0.113.25:8000")
    source.add_argument("--video", type=Path)
    source.add_argument("--image", type=Path, nargs="+")
    parser.add_argument("--key", help="the client's activation key (with --server)")
    parser.add_argument("--table", type=int, help="table number (default: the first with its camera on air)")
    parser.add_argument("--model", type=Path, default=HERE / "model" / "model.onnx")
    parser.add_argument("--conf", type=float, default=0.4, help="how sure the model must be, 0..1")
    parser.add_argument("--tiles", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--tile", type=int, default=0, help="tile side in px; smaller finds smaller cards, slower")
    parser.add_argument("--fps", type=float, default=2, help="frames per second to look at (with --video)")
    args = parser.parse_args()
    if args.server and not args.key:
        parser.error("--server needs --key")
    if not args.model.exists():
        sys.exit(f"no model at {args.model}: run python download_model.py first")
    detector = CardDetector(args.model)
    if args.server:
        live(args, detector)
    elif args.video:
        video(args, detector)
    else:
        images(args, detector)


if __name__ == "__main__":
    main()
