# Model weights

The two ONNX files this project needs are **not committed** to git (they total
~38 MB). `../install.sh --download-models` fetches them here, and verifies each
against the SHA-256 below before accepting it.

| File | Purpose | SHA-256 |
| --- | --- | --- |
| `face_detection_yunet_2023mar.onnx` | face + landmark detection | `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4` |
| `face_recognition_sface_2021dec.onnx` | 128-d face embedding | `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` |

Source: [opencv/opencv_zoo](https://github.com/opencv/opencv_zoo) — YuNet is
MIT licensed; SFace is distributed under the model zoo's terms for research and
commercial use. Review those terms yourself before redistributing the weights.

To fetch them by hand:

```bash
mkdir -p models && cd models
base=https://github.com/opencv/opencv_zoo/raw/main/models
curl -LO "$base/face_detection_yunet/face_detection_yunet_2023mar.onnx"
curl -LO "$base/face_recognition_sface/face_recognition_sface_2021dec.onnx"
sha256sum *.onnx   # compare against the table above
```
