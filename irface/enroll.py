"""Enroll a face: capture samples from the IR camera and store an averaged embedding."""
import argparse
import getpass
import sys
import numpy as np

from . import capture, pipeline, models, store

N_SAMPLES = 20
MIN_DET_SCORE = 0.7


def collect(cap, n, verbose=True):
    det, rec = models.detector(), models.recognizer()
    feats = []
    attempts = 0
    while len(feats) < n and attempts < n * 10:
        attempts += 1
        gray = cap.read_bright()
        if gray is None:
            continue
        feat, ex = pipeline.embed_face(gray, det, rec)
        if feat is None or ex.get("score", 0) < MIN_DET_SCORE:
            if verbose and attempts % 10 == 0:
                print("  ...looking for a face")
            continue
        feats.append(feat)
        if verbose:
            print(f"  sample {len(feats)}/{n}  det={ex['score']:.2f}")
    return np.stack(feats) if feats else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-u", "--user", default=getpass.getuser())
    ap.add_argument("-n", "--samples", type=int, default=N_SAMPLES)
    ap.add_argument("-d", "--device", default=capture.DEFAULT_DEVICE)
    ap.add_argument("--overwrite", action="store_true")
    args = ap.parse_args()

    if store.exists(args.user) and not args.overwrite:
        print(f"Template already exists for {args.user}. Use --overwrite to replace.")
        return 1

    print(f"Enrolling {args.user} from {args.device}")
    print("Look at the camera. Keep your face centered and still-ish.")
    with capture.IRCapture(device=args.device) as cap:
        feats = collect(cap, args.samples)
    if feats is None or len(feats) < max(5, args.samples // 2):
        print("ERROR: could not collect enough face samples. Aborting.")
        return 1

    avg = feats.mean(axis=0)
    p = store.save(args.user, avg)
    print(f"Saved {len(feats)} samples -> averaged embedding ({avg.shape[0]}-d)")
    print(f"Template written to {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
