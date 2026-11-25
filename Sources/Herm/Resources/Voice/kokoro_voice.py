"""Herm's local Kokoro worker. Network access is used by the explicit prepare command."""
import hashlib
import io
import json
import os
import struct
import sys
import wave
from contextlib import redirect_stdout
from pathlib import Path
from urllib.request import urlopen

ASSETS = {
    "kokoro-v1.0.int8.onnx": "6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb",
    "voices-v1.0.bin": "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
}
RELEASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare(root):
    for name, expected in ASSETS.items():
        final = root / name
        if final.is_file() and digest(final) == expected:
            continue
        pending = final.with_suffix(".partial")
        try:
            with urlopen(RELEASE + name, timeout=45) as response, pending.open("wb") as output:
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    if output.tell() + len(block) > 100 * 1024 * 1024:
                        raise ValueError("Kokoro asset is too large.")
                    output.write(block)
            if digest(pending) != expected:
                raise ValueError("Invalid Kokoro asset checksum.")
            os.replace(pending, final)
        finally:
            pending.unlink(missing_ok=True)
    model = load(root)
    audio, _ = model.create("Herm is ready.", voice="af_heart", lang="en-us")
    if not len(audio):
        raise ValueError("Kokoro produced no audio.")


def load(root):
    from kokoro_onnx import Kokoro
    from onnxruntime import InferenceSession, SessionOptions

    options = SessionOptions()
    options.intra_op_num_threads = 3
    session = InferenceSession(str(root / "kokoro-v1.0.int8.onnx"),
                               sess_options=options, providers=["CPUExecutionProvider"])
    return Kokoro.from_session(session, str(root / "voices-v1.0.bin"))


def wav_audio(model, request):
    audio, sample_rate = model.create(
        request["text"], voice=request["voice"], speed=request["speed"], lang=request["language"]
    )
    if not len(audio):
        raise ValueError("Kokoro produced no audio.")
    pcm = (audio.clip(-1, 1) * 32767).astype("<i2").tobytes()
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setparams((1, 2, sample_rate, 0, "NONE", "not compressed"))
        wav.writeframes(pcm)
    return output.getvalue()


def serve(root):
    with redirect_stdout(sys.stderr):
        model = load(root)
    for line in sys.stdin.buffer:
        if len(line) > 8192:
            return
        try:
            with redirect_stdout(sys.stderr):
                output = wav_audio(model, json.loads(line))
        except Exception:
            output = b""
        if len(output) > 2 * 1024 * 1024:
            output = b""
        sys.stdout.buffer.write(struct.pack("<I", len(output)) + output)
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    mode, directory = sys.argv[1:]
    root = Path(directory)
    if mode == "prepare":
        prepare(root)
    elif mode == "serve":
        serve(root)
    else:
        raise ValueError("Unrecognized Kokoro command.")
