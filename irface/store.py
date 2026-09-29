import os
import pwd
import tempfile
import numpy as np

# Optional global override (e.g. IRFACE_DATA_DIR). When set, every user's
# template lives in this single directory.
_ENV_DIR = os.environ.get("IRFACE_DATA_DIR")
_REL = os.path.join(".local", "share", "irface", "faces")


def user_faces_dir(user):
    if _ENV_DIR:
        return _ENV_DIR
    try:
        home = pwd.getpwnam(user).pw_dir
    except KeyError:
        home = os.path.expanduser("~")
    return os.path.join(home, _REL)


def template_path(user):
    return os.path.join(user_faces_dir(user), f"{user}.npy")


def save(user, embedding):
    d = user_faces_dir(user)
    os.makedirs(d, exist_ok=True)
    emb = normalize(np.asarray(embedding, np.float32))
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".npy")
    try:
        with os.fdopen(fd, "wb") as f:
            np.save(f, emb)
        os.chmod(tmp, 0o600)
        os.replace(tmp, template_path(user))
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise
    return template_path(user)


def load(user):
    p = template_path(user)
    if not os.path.exists(p):
        return None
    return np.load(p)


def exists(user):
    return os.path.exists(template_path(user))


def normalize(v):
    n = float(np.linalg.norm(v))
    if n == 0:
        return v
    return v / n


def cosine(a, b):
    a = np.asarray(a, np.float32).flatten()
    b = np.asarray(b, np.float32).flatten()
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)
