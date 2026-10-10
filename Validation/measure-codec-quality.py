#!/usr/bin/env python3
"""Synthetic, content-free codec comparison with the app's ImageIO quality setting."""
import json
import math
import pathlib
import subprocess
import tempfile
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="ScreenRecall-Codec-") as folder:
    folder = pathlib.Path(folder)
    width, height = 1440, 900
    y, x = np.mgrid[:height, :width]
    rgb = np.stack(((x * 255 // width).astype(np.uint8),
                    (y * 255 // height).astype(np.uint8),
                    (((x // 12 + y // 12) % 2) * 140 + 40).astype(np.uint8)), axis=-1)
    original = Image.fromarray(rgb, "RGB")
    draw = ImageDraw.Draw(original)
    for n in range(80):
        top = 12 + n * 11
        draw.line((40, top, 1330, top), fill=(255, 255, 255), width=1)
        draw.text((45 + (n % 5) * 200, top - 8), f"ScreenRecall 0123456789 {n:02d}", fill=(0, 0, 0))
    input_file = folder / "original.png"
    original.save(input_file)
    subprocess.run(["swift", str(ROOT / "Validation/CodecQuality.swift"), str(input_file), str(folder)], check=True)
    result = {"testImage": "synthetic gradient/checkerboard/small text", "width": width, "height": height,
              "quality": 0.88, "codecs": {}}
    a = np.asarray(original, dtype=np.float32)
    for codec in ("jpeg", "heic"):
        encoded = folder / f"test.{codec}"
        decoded = folder / f"decoded-{codec}.png"
        subprocess.run(["sips", "-s", "format", "png", str(encoded), "--out", str(decoded)],
                       stdout=subprocess.DEVNULL, check=True)
        b = np.asarray(Image.open(decoded).convert("RGB"), dtype=np.float32)
        mse = float(np.mean((a - b) ** 2))
        result["codecs"][codec] = {"bytes": encoded.stat().st_size,
                                    "psnrDb": round(10 * math.log10(255 ** 2 / mse), 2),
                                    "meanAbsoluteError": round(float(np.mean(np.abs(a - b))), 2)}
    print(json.dumps(result, indent=2))
