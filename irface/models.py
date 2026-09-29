import os
import cv2

# The daemon is idle almost all the time and a probe is a single 640x360 frame,
# so OpenCV's default pool of one thread per core is pure overhead. Capping it
# keeps the resident set and thread count down without measurably slowing a
# probe. Tunable via the environment for anyone on very different hardware.
try:
    cv2.setNumThreads(int(os.environ.get("IRFACE_THREADS", "2")))
except Exception:
    pass

_PKG_DIR = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_PKG_DIR)
MODELS_DIR = os.environ.get("IRFACE_MODELS_DIR", os.path.join(_ROOT, "models"))

YUNET = os.path.join(MODELS_DIR, "face_detection_yunet_2023mar.onnx")
SFACE = os.path.join(MODELS_DIR, "face_recognition_sface_2021dec.onnx")

_detector = None
_recognizer = None


def detector():
    global _detector
    if _detector is None:
        if not os.path.exists(YUNET):
            raise FileNotFoundError(f"YuNet model not found: {YUNET}")
        # (model, config, input_size, score_thresh, nms_thresh, top_k)
        _detector = cv2.FaceDetectorYN.create(YUNET, "", (320, 320), 0.7, 0.3, 5000)
    return _detector


def recognizer():
    global _recognizer
    if _recognizer is None:
        if not os.path.exists(SFACE):
            raise FileNotFoundError(f"SFace model not found: {SFACE}")
        _recognizer = cv2.FaceRecognizerSF.create(SFACE, "")
    return _recognizer
