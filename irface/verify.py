"""Verify identity from the IR camera against a stored template."""
import argparse
import getpass
import sys
import time

from . import capture, pipeline, models, store

DEFAULT_THRESHOLD = 0.36  # SFace LFW 1:1 operating point (cosine)
DEFAULT_TIMEOUT = 5.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-u", "--user", default=getpass.getuser())
    ap.add_argument("-d", "--device", default=capture.DEFAULT_DEVICE)
    ap.add_argument("-t", "--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    ap.add_argument("--watch", action="store_true", help="keep running, report every result")
    args = ap.parse_args()

    template = store.load(args.user)
    if template is None:
        print(f"No template for {args.user}. Run: python3 -m irface.enroll -u {args.user}")
        return 1

    det, rec = models.detector(), models.recognizer()
    print(f"Verifying {args.user} (threshold={args.threshold:.2f}) on {args.device}")
    start = time.time()
    best = 0.0
    authenticated = False

    with capture.IRCapture(device=args.device) as cap:
        while True:
            if not args.watch and (time.time() - start) > args.timeout:
                break
            gray = cap.read_bright()
            if gray is None:
                continue
            feat, ex = pipeline.embed_face(gray, det, rec)
            if feat is None:
                if args.watch:
                    print("  no face")
                continue
            sim = store.cosine(feat, template)
            best = max(best, sim)
            if args.watch:
                print(f"  sim={sim:.4f} det={ex['score']:.2f} "
                      f"{'PASS' if sim >= args.threshold else ''}")
            if sim >= args.threshold:
                authenticated = True
                if not args.watch:
                    break

    elapsed = time.time() - start
    if authenticated:
        print(f"AUTHENTICATED sim={best:.4f} in {elapsed:.2f}s")
        return 0
    print(f"FAILED best sim={best:.4f} in {elapsed:.2f}s (need {args.threshold:.2f})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
