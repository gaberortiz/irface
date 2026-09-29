import os
import cv2

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
