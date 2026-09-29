import collections
import cv2

DEFAULT_DEVICE = "/dev/video2"
WIDTH = 640
HEIGHT = 360
WARMUP_FRAMES = 10
BRIGHT_BUFFER = 4


class IRCapture:
    """Reads grayscale IR frames, handling auto-exposure warm-up and the
    camera's bright/dark frame alternation by surfacing the brightest recent
    frame."""

    def __init__(self, device=DEFAULT_DEVICE, width=WIDTH, height=HEIGHT,
                 warmup=WARMUP_FRAMES, buffer=BRIGHT_BUFFER):
        self.device = device
        self.cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not self.cap.isOpened():
            raise RuntimeError(f"cannot open IR device {device}")
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"GREY"))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self._buf = collections.deque(maxlen=buffer)
        for _ in range(warmup):
            self._read_raw()
        # prime the brightness buffer
        for _ in range(buffer):
            f = self._read_raw()
            if f is not None:
                self._buf.append(f)

    def _read_raw(self):
        ok, frame = self.cap.read()
        if not ok or frame is None:
            return None
        if frame.ndim == 3:
            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        return frame

    def read_bright(self):
        f = self._read_raw()
        if f is None:
            return None
        self._buf.append(f)
        return max(self._buf, key=lambda x: float(x.mean()))

    def read_all(self):
        return self._read_raw()

    def release(self):
        self.cap.release()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.release()
