import cv2
import numpy as np

# ArcFace/SFace reference 5 points for a 112x112 aligned face:
# left_eye, right_eye, nose, mouth_left, mouth_right
SFACE_REF = np.array([
    [38.2946, 51.6963],
    [73.5318, 51.5014],
    [56.0252, 71.7366],
    [41.5493, 92.3655],
    [70.7299, 92.2041],
], np.float32)

# YuNet emits landmarks as: right_eye, left_eye, nose, mouth_right, mouth_left.
# Empirically (see notes in README) this order already matches SFACE_REF
# positionally: mapping identity gives the tightest intra-class embeddings
# (~0.93), so no reorder is applied. A swap collapses stability to ~0.82.
YUNET_TO_ARCFACE = [0, 1, 2, 3, 4]

ALIGN_SIZE = 112


def _align(img_bgr, landmarks, ref=SFACE_REF, size=ALIGN_SIZE):
    M, _ = cv2.estimateAffinePartial2D(
        np.asarray(landmarks, np.float32), ref, method=cv2.LMEDS)
    if M is None:
        return None
    return cv2.warpAffine(img_bgr, M, (size, size),
                          flags=cv2.INTER_LINEAR)


def detect_faces(gray, det=None):
    """Return raw YuNet detection array (Nx15) or None."""
    from . import models
    det = det or models.detector()
    bgr = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    h, w = gray.shape[:2]
    det.setInputSize((w, h))
    _, faces = det.detect(bgr)
    if faces is None or len(faces) == 0:
        return None
    return faces


def embed_face(gray, det=None, rec=None, return_extras=False):
    """gray -> (embedding[128] float32, extras) or (None, extras).

    Picks the largest detected face. extras always a dict; on success it also
    carries 'box', 'landmarks' (YuNet order), 'score' and 'aligned' (BGR crop).
    """
    from . import models
    det = det or models.detector()
    faces = detect_faces(gray, det)
    if faces is None:
        return None, {}
    idx = int(np.argmax(faces[:, 2] * faces[:, 3]))
    f = faces[idx]
    box = f[:4].astype(int)
    score = float(f[-1])
    landmarks = f[4:14].reshape(5, 2)
    arc = landmarks[YUNET_TO_ARCFACE]
    bgr = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
    aligned = _align(bgr, arc)
    extras = {"box": box, "landmarks": landmarks, "score": score,
              "aligned": aligned, "n_faces": len(faces)}
    if aligned is None:
        return None, extras
    rec = rec or models.recognizer()
    feat = rec.feature(aligned).flatten().astype(np.float32)
    if return_extras:
        return feat, extras
    return feat, extras
