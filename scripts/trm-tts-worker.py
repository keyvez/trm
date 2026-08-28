#!/usr/bin/env python3
"""Persistent, streaming MLX Qwen voice worker for trm.

stdin is JSONL requests. stdout is JSONL lifecycle/audio events. Model logs may
also reach stdout; the Swift client deliberately ignores non-JSON lines.
"""

from __future__ import annotations

import base64
import json
import os
import sys

import mlx.core as mx
import numpy as np
from mlx_audio.tts.utils import load_model


MODEL = os.environ.get(
    "TRM_TTS_MODEL", "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
)
VOICE = os.environ.get("TRM_TTS_VOICE", "Ryan")


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def pcm16(audio: mx.array) -> bytes:
    mx.eval(audio)
    values = np.asarray(audio, dtype=np.float32)
    values = np.clip(values, -1.0, 1.0)
    return (values * 32767.0).astype("<i2", copy=False).tobytes()


def render(model: object, request: dict[str, object]) -> None:
    request_id = str(request.get("id", ""))
    text = str(request.get("text", "")).strip()
    if not request_id or not text:
        emit({"type": "error", "id": request_id, "message": "No briefing text."})
        return
    if len(text) > 6_000:
        emit(
            {
                "type": "error",
                "id": request_id,
                "message": "Briefing is too long; trm speaks compact updates.",
            }
        )
        return

    for result in model.generate(
        text=text,
        voice=VOICE,
        lang_code="English",
        instruct="Calm, natural, concise engineering update.",
        stream=True,
        streaming_interval=0.5,
        max_tokens=1200,
        verbose=False,
    ):
        audio = pcm16(result.audio)
        emit(
            {
                "type": "chunk",
                "id": request_id,
                "sampleRate": result.sample_rate,
                "pcm": base64.b64encode(audio).decode("ascii"),
            }
        )
    emit({"type": "end", "id": request_id})


def main() -> int:
    model = load_model(MODEL)
    emit({"type": "ready", "backend": "mlx-qwen-0.6b", "voice": VOICE})

    for raw_line in sys.stdin:
        try:
            request = json.loads(raw_line)
            render(model, request)
        except Exception as error:
            request_id = ""
            try:
                request_id = str(request.get("id", ""))
            except Exception:
                pass
            emit({"type": "error", "id": request_id, "message": str(error)})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        emit({"type": "fatal", "message": f"Local speech failed: {error}"})
        raise SystemExit(1)
