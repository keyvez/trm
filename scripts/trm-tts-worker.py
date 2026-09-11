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
import queue
import sys
import threading

import mlx.core as mx
import numpy as np
from mlx_audio.tts.utils import load_model


MODEL = os.environ.get(
    "TRM_TTS_MODEL", "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
)
VOICE = os.environ.get("TRM_TTS_VOICE", "Ryan")

# How the reading should sound when the app does not say. The app sends its own
# `instruct` per request — a voice description plus a mood earned from the
# transcript — so this is only the floor.
#
# Note that a *CustomVoice* checkpoint ignores this entirely: it clones the
# speaker named by `voice` and takes no direction. Mood needs a VoiceDesign
# model, selected with TRM_TTS_MODEL.
DEFAULT_INSTRUCT = os.environ.get(
    "TRM_TTS_INSTRUCT", "Calm, natural, concise engineering update."
)


_cancel_lock = threading.Lock()
_cancelled: set[str] = set()


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def cancelled(request_id: str) -> bool:
    with _cancel_lock:
        return request_id in _cancelled


def forget(request_id: str) -> None:
    """Drop a request from the cancel set once it can no longer be running."""
    with _cancel_lock:
        _cancelled.discard(request_id)


def read_stdin(requests: "queue.Queue[dict | None]") -> None:
    """Read requests on their own thread so a cancel can land mid-render.

    Rendering blocks: one generate() call per segment, each taking about as
    long as the audio it makes. A worker that only looked at stdin between
    requests therefore could not be interrupted at all — stopping playback
    left the whole reply still being synthesised, and the next request sat
    unread in the pipe behind it. Press play again and nothing happened until
    the reading you had already abandoned had finished in full.

    A cancel is `{"id": ..., "cancel": true}`. It never joins the queue: it is
    a note about a request that is already in it, or already running.
    """
    for raw_line in sys.stdin:
        try:
            request = json.loads(raw_line)
        except Exception:
            continue
        if not isinstance(request, dict):
            continue
        if request.get("cancel"):
            with _cancel_lock:
                _cancelled.add(str(request.get("id", "")))
            continue
        requests.put(request)
    # stdin closed: the app has gone.
    requests.put(None)


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
    # Cancelled while it waited its turn: never start it.
    if cancelled(request_id):
        forget(request_id)
        emit({"type": "end", "id": request_id, "cancelled": True})
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
    instruct = str(request.get("instruct") or DEFAULT_INSTRUCT)
    for index, segment in enumerate(segments(text)):
        if cancelled(request_id):
            break
        for result in model.generate(
            text=segment,
            voice=VOICE,
            lang_code="English",
            instruct=instruct,
            stream=True,
            streaming_interval=0.5,
            max_tokens=1200,
            verbose=False,
        ):
            # Checked per chunk, not per segment: a segment is a few hundred
            # characters and someone who has stopped listening should not wait
            # out the rest of it. Breaking stops pulling from the generator,
            # so the cost of a cancel is the chunk already in flight — about
            # half a second of audio.
            if cancelled(request_id):
                break
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
    was_cancelled = cancelled(request_id)
    forget(request_id)
    emit({"type": "end", "id": request_id, "cancelled": was_cancelled})


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
    # Started before the model loads, so a cancel sent during those several
    # seconds is already recorded when the request it belongs to comes up.
    requests: "queue.Queue[dict | None]" = queue.Queue()
    threading.Thread(target=read_stdin, args=(requests,), daemon=True).start()

    model = load_model(MODEL)
    emit({"type": "ready", "backend": "mlx-qwen-0.6b", "voice": VOICE})

    while True:
        request = requests.get()
        if request is None:
            return 0
        try:
            render(model, request)
        except Exception as error:
            request_id = ""
            try:
                request_id = str(request.get("id", ""))
            except Exception:
                pass
            forget(request_id)
            emit({"type": "error", "id": request_id, "message": str(error)})


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        emit({"type": "fatal", "message": f"Local speech failed: {error}"})
        raise SystemExit(1)
