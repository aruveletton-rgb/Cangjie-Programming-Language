#!/usr/bin/env bash
# 把 Linux 构建产物打成一个自包含部署包（对应 Windows 的 package-cloud.ps1）。
#
# 用法：
#   ./package-cloud-linux.sh --build-root /tmp/ict_backend_xxx --out ./ict-cloud-linux
#
# 产物结构：
#   ict-cloud-linux/
#     main                仓颉后端二进制
#     stdx/               stdx 运行库（.so + .cjo）
#     data/               合成数据（演示用；正式环境须替换为已授权数据）
#     deploy/             启动/自检脚本与环境模板
#     bundle-manifest.json 文件清单与 sha256
#
# 状态：未在 Linux 实机验证（2026-10-25 编写）。

set -euo pipefail

BUILD_ROOT=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-root) BUILD_ROOT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$BUILD_ROOT" ]]; then echo "缺少 --build-root" >&2; exit 2; fi
if [[ ! -d "$BUILD_ROOT" ]]; then echo "build-root 不存在: $BUILD_ROOT" >&2; exit 2; fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/artifacts/backend/cloud-bundle-linux"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

BIN=""
for candidate in "$BUILD_ROOT/backend/target/release/bin/main" \
                 "$BUILD_ROOT/backend/target/release/main" \
                 "$BUILD_ROOT/backend/main"; do
  [[ -f "$candidate" ]] && { BIN="$candidate"; break; }
done
[[ -n "$BIN" ]] || { echo "未找到二进制，检查构建产物路径" >&2; exit 3; }
[[ -d "$BUILD_ROOT/stdx" ]] || { echo "未找到 stdx 目录" >&2; exit 3; }

if [[ -e "$OUT" ]]; then
  echo "输出目录已存在，先移开或换 --out: $OUT" >&2
  exit 4
fi

mkdir -p "$OUT"/{deploy,data}
cp "$BIN" "$OUT/main"
chmod +x "$OUT/main"
cp -r "$BUILD_ROOT/stdx" "$OUT/stdx"
cp "$REPO_ROOT/src/data/synthetic.runtime.json" "$OUT/data/synthetic.runtime.json"

for f in tls-proxy.mjs preflight-provider.mjs preflight-deploy.mjs \
         provider.env.example gen-cert.sh start-cloud.sh stop-cloud.sh \
         ict-backend.service nginx-campus.conf; do
  [[ -f "$HERE/$f" ]] && cp "$HERE/$f" "$OUT/deploy/$f"
done
chmod +x "$OUT/deploy"/*.sh || true

python3 - "$OUT" "$BUILD_ROOT" <<'PY'
import hashlib, json, os, sys
out, build_root = sys.argv[1], sys.argv[2]
files = []
for base, _, names in os.walk(out):
    for name in names:
        if name == "bundle-manifest.json":
            continue
        path = os.path.join(base, name)
        rel = os.path.relpath(path, out).replace(os.sep, "/")
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        files.append({"path": rel, "bytes": os.path.getsize(path), "sha256": h.hexdigest()})
manifest = {
    "schema": "ict-cloud-bundle-v1",
    "target": "x86_64-unknown-linux-gnu",
    "hostImage": "Ubuntu 22.04 / openEuler 22.03",
    "buildRoot": build_root,
    "entry": {
        "backend": "main",
        "service": "deploy/ict-backend.service",
        "proxy": "deploy/nginx-campus.conf",
        "tlsProxyFallback": "deploy/tls-proxy.mjs",
    },
    "files": sorted(files, key=lambda x: x["path"]),
}
with open(os.path.join(out, "bundle-manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
main = next(f for f in manifest["files"] if f["path"] == "main")
print(f"bundle={out}")
print(f"files={len(manifest['files'])}")
print(f"main sha256={main['sha256']}")
PY
