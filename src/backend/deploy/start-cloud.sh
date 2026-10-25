#!/usr/bin/env bash
# 在 Linux 上启动部署包（前台调试用；生产用 systemd + Nginx，见 ict-backend.service）。
#
# 用法：
#   ./start-cloud.sh                          # 回环模式，仅供本机自检
#   ICT_PUBLIC_ORIGIN=https://example.cn ./start-cloud.sh   # 公网模式（强制 session 认证）
#
# 注意：设置 ICT_PUBLIC_ORIGIN 后，服务只接受服务端签发的会话令牌，
#       静态演示令牌（demo 模式）会启动失败，这是设计行为，不是故障。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${ICT_PORT:-38082}"

[[ -f "$ROOT/main" ]] || { echo "main 不存在：$ROOT/main" >&2; exit 2; }
mkdir -p "$ROOT/state" "$ROOT/logs"

export LD_LIBRARY_PATH="$ROOT/stdx:${LD_LIBRARY_PATH:-}"
export ICT_PORT="$PORT"
export ICT_DATA="${ICT_DATA:-$ROOT/data/synthetic.runtime.json}"
export ICT_STORE="${ICT_STORE:-$ROOT/state/store.json}"
export ICT_CONFIRM_TTL="${ICT_CONFIRM_TTL:-300}"
export ICT_ENABLE_TEST_FAULTS=0
# 回环来源始终放行；公网来源由 ICT_PUBLIC_ORIGIN 单独声明，两者不互相替代。
export ICT_CORS="${ICT_CORS:-http://127.0.0.1:5173,http://localhost:5173}"

echo "== 启动后端 port=$PORT publicOrigin=${ICT_PUBLIC_ORIGIN:-<none>}"
"$ROOT/main" >>"$ROOT/logs/backend.stdout.log" 2>>"$ROOT/logs/backend.stderr.log" &
PID=$!
echo "$PID" > "$ROOT/state/backend.pid"

for _ in $(seq 1 40); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "后端提前退出，stderr 末尾：" >&2
    tail -20 "$ROOT/logs/backend.stderr.log" >&2 || true
    exit 3
  fi
  body="$(curl -s --max-time 1 "http://127.0.0.1:$PORT/health" || true)"
  if [[ "$body" == *'"code"'*'"OK"'* ]]; then
    echo "== health OK"
    echo "$body"
    echo "   pid=$PID  log=$ROOT/logs/backend.stdout.log"
    exit 0
  fi
  sleep 0.25
done

echo "健康检查超时，stderr 末尾：" >&2
tail -20 "$ROOT/logs/backend.stderr.log" >&2 || true
exit 4
