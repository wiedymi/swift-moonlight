#!/usr/bin/env bash
set -euo pipefail

port="${1:-8765}"
duration_seconds="${2:-0}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Serving Swift Moonlight input visual target on port ${port}"
echo "Open this on the streamed host: http://<mac-ip>:${port}/input-visual-target.html"
echo "Local URL: http://127.0.0.1:${port}/input-visual-target.html"
if [[ "${duration_seconds}" != "0" ]]; then
  echo "Auto-stop after ${duration_seconds}s"
else
  echo "Press Ctrl-C to stop, or pass a second argument with an auto-stop timeout in seconds."
fi

cd "${repo_root}"
if [[ "${duration_seconds}" == "0" ]]; then
  exec python3 -m http.server "${port}" --directory docs
fi

python3 -m http.server "${port}" --directory docs &
server_pid="$!"
trap 'kill "${server_pid}" 2>/dev/null || true' EXIT INT TERM
sleep "${duration_seconds}"
