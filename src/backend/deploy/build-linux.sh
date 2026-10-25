#!/usr/bin/env bash
# 在 Linux 上构建仓颉后端（C1—C6），产物与 Windows 构建一一对应。
#
# 用途：Flexus L / ECS 等 Linux 主机首次部署时使用。
# 状态：**未在 Linux 实机验证**（2026-10-25 编写）。首次运行请按 docs/deploy_runbook_20261025.md 逐步核对。
#
# 前置：
#   1. 已安装 Linux 版仓颉 SDK，且 `cjc --version` 可用（官网下载中心提供 Linux 包）
#   2. 已下载 stdx Linux 包，并 export STDX_DIR=<.../linux_x86_64_cjnative/dynamic/stdx>
#   3. 仓库已 clone（含 src/cj_zh_search、src/backend、src/data）
#
# 用法：
#   ./build-linux.sh            # 构建
#   ./build-linux.sh --test     # 构建并跑单测
#
# 说明：仓颉对非 ASCII 路径敏感，本脚本一律在 ASCII 临时目录中构建，
#       不改动系统 locale，也不在源码树内产生中间产物。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUN_TESTS=0
[[ "${1:-}" == "--test" ]] && RUN_TESTS=1

if [[ -z "${STDX_DIR:-}" ]]; then
  echo "ERROR: STDX_DIR 未设置。指向 Linux 版 stdx 目录（内含 stdx.net.http.cjo 等）。" >&2
  exit 2
fi
if [[ ! -f "$STDX_DIR/stdx.net.http.cjo" ]]; then
  echo "ERROR: $STDX_DIR 下没有 stdx.net.http.cjo，STDX_DIR 可能指错了层级。" >&2
  exit 2
fi
if ! command -v cjc >/dev/null 2>&1; then
  echo "ERROR: 找不到 cjc。请先 source 仓颉 SDK 的 envsetup.sh 或把 bin 加入 PATH。" >&2
  exit 2
fi

TARGET="x86_64-unknown-linux-gnu"
BUILD_ROOT="$(mktemp -d "/tmp/ict_backend_$(date +%Y%m%dT%H%M%S)_XXXX")"
AUDIT_DIR="$REPO_ROOT/audit/backend/$(date +%Y%m%dT%H%M%S)_build_linux"
mkdir -p "$AUDIT_DIR"

echo "== 源码复制到 ASCII 构建目录"
cp -r "$REPO_ROOT/src/cj_zh_search" "$BUILD_ROOT/cj_zh_search"
cp -r "$REPO_ROOT/src/backend" "$BUILD_ROOT/backend"
cp -r "$STDX_DIR" "$BUILD_ROOT/stdx"
echo "   buildRoot=$BUILD_ROOT"

echo "== 解析 stdx 传递依赖"
mapfile -t LIBS < <(
  python3 - "$BUILD_ROOT/stdx" <<'PY'
import json, subprocess, sys
root = sys.argv[1]
seen, queue = set(), ["stdx.net.http", "stdx.encoding.json"]
while queue:
    pkg = queue.pop(0)
    if pkg in seen:
        continue
    seen.add(pkg)
    out = subprocess.run(["cjc", "--scan-dependency", f"{root}/{pkg}.cjo"],
                         capture_output=True, text=True, check=True).stdout
    for dep in json.loads(out).get("dependencies", []):
        if not dep.get("isStd") and dep["package"] not in seen:
            queue.append(dep["package"])
print("\n".join(sorted(seen)))
PY
)
if [[ ${#LIBS[@]} -eq 0 ]]; then
  echo "ERROR: stdx 依赖解析为空。" >&2
  exit 3
fi
printf '   %s\n' "${LIBS[@]}"

echo "== 生成 cjpm.toml 的 stdx 绑定（仅构建副本）"
CONFIG="$BUILD_ROOT/backend/cjpm.toml"
LINKS=""
for lib in "${LIBS[@]}"; do LINKS="$LINKS -l$lib"; done
python3 - "$CONFIG" "$BUILD_ROOT/stdx" "$TARGET" "$LINKS" <<'PY'
import sys
config_path, stdx, target, links = sys.argv[1:5]
text = open(config_path, encoding="utf-8").read()
options = (
    f"compile-option = '--import-path \"{stdx}\"'\n"
    f"link-option = '-L\"{stdx}\"{links}'\n"
)
text = text.replace("[dependencies]", options + "\n[dependencies]", 1)
text += f"\n[target.{target}.bin-dependencies.package-option]\n"
import glob, os
for cjo in sorted(glob.glob(os.path.join(stdx, "*.cjo"))):
    name = os.path.basename(cjo)[:-4]
    text += f'"{name}" = "{cjo}"\n'
open(config_path, "w", encoding="utf-8").write(text)
PY

echo "== cjpm build"
cd "$BUILD_ROOT/backend"
export LD_LIBRARY_PATH="$BUILD_ROOT/stdx:${LD_LIBRARY_PATH:-}"
export ICT_DATA="$REPO_ROOT/src/data/synthetic.runtime.json"
set +e
cjpm build 2>&1 | tee "$AUDIT_DIR/build.log"
BUILD_CODE=${PIPESTATUS[0]}
set -e
echo "   exit=$BUILD_CODE"

TEST_CODE="skipped"
if [[ $BUILD_CODE -eq 0 && $RUN_TESTS -eq 1 ]]; then
  echo "== cjpm test"
  set +e
  cjpm test 2>&1 | tee "$AUDIT_DIR/test.log"
  TEST_CODE=${PIPESTATUS[0]}
  set -e
  echo "   exit=$TEST_CODE"
fi

BIN=""
for candidate in "$BUILD_ROOT/backend/target/release/bin/main" \
                 "$BUILD_ROOT/backend/target/release/main" \
                 "$BUILD_ROOT/backend/main"; do
  if [[ -f "$candidate" ]]; then BIN="$candidate"; break; fi
done

cat > "$AUDIT_DIR/result.json" <<JSON
{
  "schema": "ict-build-linux-v1",
  "completedAt": "$(date -Iseconds)",
  "target": "$TARGET",
  "buildRoot": "$BUILD_ROOT",
  "libraries": [$(printf '"%s",' "${LIBS[@]}" | sed 's/,$//')],
  "buildExitCode": $BUILD_CODE,
  "testExitCode": "$TEST_CODE",
  "binary": "$BIN",
  "verified": false,
  "note": "脚本首次编写，未经 Linux 实机验证；verified 由首次成功运行后人工改为 true"
}
JSON

echo
echo "== 结果"
echo "   audit=$AUDIT_DIR/result.json"
if [[ -z "$BIN" ]]; then
  echo "   ERROR: 未找到产物二进制，请检查 build.log 中 target 目录结构。" >&2
  exit 4
fi
echo "   binary=$BIN"
echo "   sha256=$(sha256sum "$BIN" | cut -d' ' -f1)"
[[ $BUILD_CODE -eq 0 ]] || exit $BUILD_CODE
[[ "$TEST_CODE" == "0" || "$TEST_CODE" == "skipped" ]] || exit $TEST_CODE
echo "   下一步：./package-cloud-linux.sh --build-root $BUILD_ROOT"
