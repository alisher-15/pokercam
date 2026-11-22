"""Downloads the test model into model/: sroot/lgd-cards-gen3 from Hugging Face, at a fixed revision, checked by
sha256. AGPL-3.0 weights: for this internal test only, never in the product (see README)."""

import hashlib
import urllib.request
from pathlib import Path

REPO = "sroot/lgd-cards-gen3"
REVISION = "b2e9e89cc0138a70fc3ac5661922f99b4e3ae135"
FILES = {
    "model.onnx": "8b767cdfed2c8e954a9134013ac3d2f2c53be048768d559675be01277a8a8fd1",
    "model.classes.json": "8a2d7e9dacf245aca5ef5a402cb404def919e9994e9142644d80c6d6248ee038",
}

target = Path(__file__).with_name("model")
target.mkdir(exist_ok=True)
for name, digest in FILES.items():
    path = target / name
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        print(f"{name}: already here")
        continue
    url = f"https://huggingface.co/{REPO}/resolve/{REVISION}/{name}"
    data = urllib.request.urlopen(url, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"{name}: checksum mismatch, not saved")
    path.write_bytes(data)
    print(f"{name}: {len(data) // 1024} KB")
