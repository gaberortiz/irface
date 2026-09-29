"""Capture IR frames, detect faces, dump raw/overlay/aligned images for inspection."""
import os
import sys
import cv2
import numpy as np

from . import capture, pipeline, models

OUT = os.environ.get("IRFACE_DEBUG_DIR", "/tmp/opencode/irface_debug")


def main():
    os.makedirs(OUT, exist_ok=True)
    with capture.IRCapture() as cap:
        for i in range(5):
            gray = cap.read_bright()
            if gray is None:
                continue
            cv2.imwrite(os.path.join(OUT, f"raw_{i}.png"), gray)
            feat, ex = pipeline.embed_face(gray)
            if not ex:
                print(f"frame {i}: no face detected (mean={gray.mean():.1f})")
                continue
            box, lm, score = ex["box"], ex["landmarks"], ex["score"]
            print(f"frame {i}: faces={ex['n_faces']} score={score:.3f} "
                  f"box={box.tolist()} feat={'ok' if feat is not None else 'FAIL'}")
            # overlay
            bgr = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
            x, y, w, h = box
            cv2.rectangle(bgr, (x, y), (x + w, y + h), (0, 255, 0), 2)
            for (px, py) in lm:
                cv2.circle(bgr, (int(px), int(py)), 2, (0, 0, 255), -1)
            cv2.imwrite(os.path.join(OUT, f"overlay_{i}.png"), bgr)
            if ex.get("aligned") is not None:
                cv2.imwrite(os.path.join(OUT, f"aligned_{i}.png"),
                            ex["aligned"])
    print("wrote debug images to", OUT)


if __name__ == "__main__":
    sys.exit(main())
