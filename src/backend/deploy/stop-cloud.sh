#!/usr/bin/env bash
# 停止 start-cloud.sh 启动的后端进程。systemd 管理时改用 systemctl stop ict-backend。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/state/backend.pid"

if [[ ! -f "$PIDFILE" ]]; then
  echo "没有 pid 文件，可能未通过 start-cloud.sh 启动。"
  exit 0
fi

PID="$(cat "$PIDFILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  for _ in $(seq 1 20); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
  done
  kill -0 "$PID" 2>/dev/null && kill -9 "$PID" || true
  echo "已停止 pid=$PID"
else
  echo "进程 $PID 已不存在"
fi
rm -f "$PIDFILE"
