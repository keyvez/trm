#!/usr/bin/env python3
"""Persistent, streaming MLX Qwen voice worker for trm.

stdin is JSONL requests. stdout is JSONL lifecycle/audio events. Model logs may
also reach stdout; the Swift client deliberately ignores non-JSON lines.
"""

from __future__ import annotations

import base64
import re
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
    if len(text) > 200_000:
        emit(
            {
                "type": "error",
                "id": request_id,
                "message": "That reply is too long to speak.",
            }
        )
        return

    # One generate() call per segment.
    #
    # max_tokens caps the AUDIO a single call may produce, so a long reply used
    # to stop dead partway through — the ceiling was reached and generation
    # simply ended, with no error to show for it. A briefing fit under it and a
    # full reading does not, which is why this only appeared once the play
    # button started reading everything. Segments are sentences grouped to a
    # few hundred characters, well inside the ceiling, and their boundaries are
    # what playback seeks to when you skip back.
    for index, segment in enumerate(segments(text)):
        for result in model.generate(
            text=segment,
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
                    "segment": index,
                    "sampleRate": result.sample_rate,
                    "pcm": base64.b64encode(audio).decode("ascii"),
                }
            )
    emit({"type": "end", "id": request_id})


SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def segments(text, limit=320):
    """Sentences, grouped up to `limit` characters.

    Grouping rather than one call per sentence: a call has fixed overhead and
    the prosody of a whole clause is better than of a fragment. Splitting at
    all is what keeps any one call under its token ceiling.
    """
    out = []
    current = ""
    for sentence in SENTENCE_END.split(text.strip()):
        sentence = sentence.strip()
        if not sentence:
            continue
        # A single sentence longer than the limit is split on whitespace; the
        # alternative is handing the model something it will truncate.
        while len(sentence) > limit:
            cut = sentence.rfind(" ", 0, limit)
            if cut <= 0:
                cut = limit
            out.append(sentence[:cut].strip())
            sentence = sentence[cut:].strip()
        if not current:
            current = sentence
        elif len(current) + 1 + len(sentence) <= limit:
            current = current + " " + sentence
        else:
            out.append(current)
            current = sentence
    if current:
        out.append(current)
    return out


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
