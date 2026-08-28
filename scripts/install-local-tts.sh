#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
install_dir="${TRM_TTS_HOME:-$HOME/.trm/tts}"
venv_dir="$install_dir/venv"
model_id="${TRM_TTS_MODEL:-mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit}"

if command -v uv >/dev/null 2>&1; then
    uv_bin="$(command -v uv)"
elif [[ -x "$HOME/.local/bin/uv" ]]; then
    uv_bin="$HOME/.local/bin/uv"
else
    echo "uv is required to install trm's isolated TTS runtime." >&2
    exit 1
fi

mkdir -p "$install_dir"
if [[ ! -x "$venv_dir/bin/python" ]]; then
    "$uv_bin" venv "$venv_dir" --python 3.11
fi
"$uv_bin" pip install --python "$venv_dir/bin/python" \
    'mlx-audio==0.5.0'
install -m 755 "$script_dir/trm-tts-worker.py" "$install_dir/trm-tts-worker.py"

"$venv_dir/bin/python" - "$model_id" <<'PY'
import sys
from huggingface_hub import snapshot_download

snapshot_download(repo_id=sys.argv[1])
PY

smoke_file="$(mktemp "${TMPDIR:-/tmp}/trm-tts-smoke.XXXXXX.jsonl")"
trap 'rm -f "$smoke_file"' EXIT
printf '%s\n' '{"id":"install-smoke","text":"Local developer briefings are ready."}' | \
    "$venv_dir/bin/python" "$install_dir/trm-tts-worker.py" >"$smoke_file"
grep -q '"type":"chunk"' "$smoke_file"
grep -q '"type":"end"' "$smoke_file"

echo "trm streaming MLX Qwen voice installed at $install_dir"
