"""Shared recognition loop: authenticate a live IR frame against a template."""
import time

from . import capture, pipeline, models, store


def authenticate(cap, template, threshold, timeout, det=None, rec=None,
                 on_frame=None):
    """Loop the camera until a face matches (sim>=threshold) or timeout.

    Returns (ok: bool, best_sim: float). on_frame(sim, extras) is optional
    per-iteration callback (used by --watch style callers).
    """
    det = det or models.detector()
    rec = rec or models.recognizer()
    start = time.time()
    best = 0.0
    while time.time() - start < timeout:
        gray = cap.read_bright()
        if gray is None:
            continue
        feat, ex = pipeline.embed_face(gray, det, rec)
        if feat is None:
            if on_frame:
                on_frame(None, ex)
            continue
        sim = store.cosine(feat, template)
        best = max(best, sim)
        if on_frame:
            on_frame(sim, ex)
        if sim >= threshold:
            return True, sim
    return False, best
