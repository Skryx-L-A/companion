#!/bin/bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# install-speech.sh — installs what the companion's local speech needs on a Mac.
#
# The setup assistant connects one mlx_audio.server for listening and speaking
# (LocalSpeechSetup in Sources/CompanionUI/Models/SetupEndpoints.swift). This is how that
# server and its models get onto the machine: mlx-audio as a uv tool, which puts
# mlx_audio.server on PATH, and the models in the Hugging Face cache the server reads from.
# It starts nothing and plays nothing; the daemon starts the server itself at the first
# voice request, once the setup allowed it.
#
#   parakeet-tdt-0.6b-v3   listening, 25 languages including German
#   Kokoro-82M             speaking, English; small and fast, the fallback
#   Breeze TTS 2, 4-bit    speaking, English and Chinese; the default voice since 2026-09-10
#
# Breeze TTS 2's weights are licensed for research and non-commercial use only (BreezeBlue
# Research and Non-Commercial License). --no-breeze leaves them out.
#
# The mlx-audio installation is shared: `tts`, the daemon's speech server and anything else
# that runs mlx_audio.server start from it. So the script refuses while a server from it is
# running, and when it changes the installed version it writes down how the installation
# looked before, next to its log, as a script that puts it back:
#
#   ${XDG_STATE_HOME:-~/.local/state}/companion/install-speech/
#     install-speech.log          one line per run that changed the version
#     vorher-<zeit>.txt           the packages of the installation before that run
#     rueckweg-<zeit>.sh          reinstalls exactly those
#
# Usage: install-speech.sh [--no-breeze]
#        install-speech.sh --rueckweg [rueckweg-<zeit>.sh]   newest one when none is named
set -euo pipefail

# The first mlx-audio release with Breeze TTS 2 (model family breeze_tts, added 2026-08-26).
MLX_AUDIO_MIN="0.5.1"
BREEZE_MODEL="mlx-community/Breeze-TTS-2-mlx-4bit"
MODELS=(mlx-community/parakeet-tdt-0.6b-v3 mlx-community/Kokoro-82M-bf16)

# Kokoro's English phonemiser and the spaCy model it reads. Without the model, misaki tries
# to download it at the first English sentence through `uv pip`, which fails inside a tool
# environment ("No virtual environment found"), and the answer breaks off.
SPACY_MODEL="en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

WITH_BREEZE=1
ROLLBACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-breeze) WITH_BREEZE=0; shift ;;
    --rueckweg)
      ROLLBACK="newest"; shift
      if [ $# -gt 0 ]; then ROLLBACK="$1"; shift; fi
      ;;
    *) echo "install-speech.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done
if [ "$WITH_BREEZE" = 1 ]; then
  MODELS+=("$BREEZE_MODEL")
fi

if ! command -v uv >/dev/null; then
  echo "install-speech.sh: needs uv (https://docs.astral.sh/uv/)" >&2
  exit 1
fi

TOOL_DIR="$(uv tool dir)"
BIN_DIR="$(uv tool dir --bin)"
PYTHON="$TOOL_DIR/mlx-audio/bin/python"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/companion/install-speech"
LOG="$STATE_DIR/install-speech.log"
mkdir -p "$STATE_DIR"

# A server started from this installation keeps running on the files an upgrade replaces,
# and the next request it loads a model for would mix old and new. The pattern names the
# two paths such a process carries in its command line: the interpreter of the tool
# environment and the entry point in the bin directory.
refuse_while_serving() {
  local pids
  pids="$(pgrep -f -- "$TOOL_DIR/mlx-audio/bin/|$BIN_DIR/mlx_audio\.server" || true)"
  if [ -n "$pids" ]; then
    echo "install-speech.sh: a speech server from this installation is running (pid $(echo $pids))." >&2
    echo "install-speech.sh: stop the companion daemon, or wait until it stops the idle server, then run this again." >&2
    exit 3
  fi
}

installed_version() {
  if [ -x "$PYTHON" ]; then
    "$PYTHON" -c 'import importlib.metadata as m; print(m.version("mlx-audio"))' 2>/dev/null || echo unknown
  else
    echo none
  fi
}

if [ -n "$ROLLBACK" ]; then
  if [ "$ROLLBACK" = newest ]; then
    ROLLBACK="$(ls -1 "$STATE_DIR"/rueckweg-*.sh 2>/dev/null | sort | tail -n 1 || true)"
  elif [ "${ROLLBACK#/}" = "$ROLLBACK" ] && [ ! -f "$ROLLBACK" ]; then
    ROLLBACK="$STATE_DIR/$ROLLBACK"
  fi
  if [ -z "$ROLLBACK" ] || [ ! -f "$ROLLBACK" ]; then
    echo "install-speech.sh: no way back recorded in $STATE_DIR; no earlier run changed the installed version" >&2
    exit 1
  fi
  refuse_while_serving
  echo "install-speech.sh: going back with $ROLLBACK" >&2
  bash "$ROLLBACK"
  echo "$(date '+%Y-%m-%d %H:%M:%S') rueckweg $(basename "$ROLLBACK"): mlx-audio now $(installed_version)" >> "$LOG"
  exit 0
fi

refuse_while_serving

# The installation as it is now, before anything replaces it. Kept only if the version
# really changes below: a run that installs what was already there has nothing to go back to.
STAMP="$(date '+%Y%m%d-%H%M%S')"
BEFORE_VERSION="$(installed_version)"
BEFORE_FILE="$STATE_DIR/vorher-$STAMP.txt"
ROLLBACK_FILE="$STATE_DIR/rueckweg-$STAMP.sh"
if [ "$BEFORE_VERSION" != none ]; then
  uv pip freeze --python "$PYTHON" > "$BEFORE_FILE"
fi

# [server]: since the 0.5 releases fastapi and uvicorn are an extra, and without it
# mlx_audio.server ends at startup with "No module named 'uvicorn'" (measured 2026-09-10).
uv tool install --upgrade "mlx-audio[server]>=$MLX_AUDIO_MIN" \
  --with "misaki[en]" --with "$SPACY_MODEL"

if [ ! -x "$PYTHON" ]; then
  echo "install-speech.sh: mlx-audio is installed, but $PYTHON is missing" >&2
  exit 1
fi
AFTER_VERSION="$(installed_version)"

if [ "$BEFORE_VERSION" != none ] && [ "$BEFORE_VERSION" != "$AFTER_VERSION" ]; then
  {
    echo '#!/bin/bash'
    echo "# Written by install-speech.sh on $STAMP: puts back mlx-audio $BEFORE_VERSION with the"
    echo "# packages it had then ($(basename "$BEFORE_FILE")). Run it through install-speech.sh --rueckweg,"
    echo "# which first checks that no speech server from this installation is running."
    echo 'set -euo pipefail'
    printf 'uv tool install --force %q --with-requirements %q\n' \
      "mlx-audio==$BEFORE_VERSION" "$BEFORE_FILE"
  } > "$ROLLBACK_FILE"
  chmod +x "$ROLLBACK_FILE"
  echo "$STAMP mlx-audio $BEFORE_VERSION -> $AFTER_VERSION, rueckweg: $(basename "$ROLLBACK_FILE")" >> "$LOG"
  echo "install-speech.sh: mlx-audio $BEFORE_VERSION -> $AFTER_VERSION; back with: $0 --rueckweg" >&2
else
  rm -f "$BEFORE_FILE"
fi

# HF_HUB_DISABLE_XET: the Xet download backend stalled at zero bytes per minute on this
# house's machines while the plain HTTP path ran at full speed (2026-08-07, again 2026-09-10).
# The ignore list keeps demo media out: the 4-bit Breeze repository carries a video that no
# model needs, and without the list it is downloaded every time, and an offline run stops at
# it as an "incomplete snapshot" (measured 2026-09-11).
for model in "${MODELS[@]}"; do
  echo "install-speech.sh: $model" >&2
  HF_HUB_DISABLE_XET=1 "$PYTHON" -c \
    'import sys; from huggingface_hub import snapshot_download; print(snapshot_download(sys.argv[1], ignore_patterns=["*.mp4", "*.mov", "*.gif"]))' \
    "$model"
done

echo "install-speech.sh: speech server at $BIN_DIR/mlx_audio.server" >&2
