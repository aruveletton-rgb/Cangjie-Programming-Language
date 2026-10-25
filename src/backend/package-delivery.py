"""Package the workspace into a self-contained delivery zip.

Promoted from temp/backend/package_workspace.py (2026-10-24) so the packaging step is
reproducible instead of living in a directory that gets cleaned. Two changes:

  1. the stamp is a CLI argument instead of a literal;
  2. every artifacts/backend/delivery_* directory is excluded, not just the output one.
     Without this the previous delivery zip is packaged into the new one, roughly
     doubling the archive for no reason.

The index is written before the archive and deliberately does not list itself, so there
is no self-referential hash. The archive hash lives outside the archive.

Usage:
  python src/backend/package-delivery.py                 # stamp = today (Asia/Shanghai)
  python src/backend/package-delivery.py --stamp 20261025
"""
import argparse
import hashlib
import json
import os
import zipfile
from datetime import datetime, timezone, timedelta

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)

parser = argparse.ArgumentParser()
parser.add_argument('--stamp', default=datetime.now(timezone(timedelta(hours=8))).strftime('%Y%m%d'))
args = parser.parse_args()

STAMP = args.stamp
ROOT_PREFIX = f'HuaweiICT_workspace_{STAMP}'
OUT_DIR = f'artifacts/backend/delivery_{STAMP}'
ZIP_NAME = f'HuaweiICT_workspace_{STAMP}.zip'
FIXED_TIME = (2026, 10, 25, 0, 0, 0)

INCLUDE_DIRS = ['src', 'docs', 'audit', 'artifacts']
INCLUDE_FILES = ['AGENTS.md']

EXCLUDE_DIR_NAMES = {
    'node_modules', '.git', '__pycache__', '.pytest_cache', '.hvigor',
    '.playwright-cli', '.workbuddy-ai', 'temp', 'output',
}
# Any previous delivery directory, not only this run's output.
EXCLUDE_PATH_PREFIXES = [f'artifacts/backend/delivery_{STAMP}/']
EXCLUDE_PATH_GLOBS = ['artifacts/backend/delivery_']
EXCLUDE_SUFFIXES = ('.pyc', '.pyo', '.log.tmp')


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def category_of(rel):
    head = rel.split('/')[0]
    if head in ('src', 'docs', 'audit', 'artifacts'):
        return head
    return 'root'


def excluded(rel, name):
    if any(rel.startswith(prefix) for prefix in EXCLUDE_PATH_PREFIXES):
        return True
    if any(rel.startswith(glob) for glob in EXCLUDE_PATH_GLOBS):
        return True
    if any(part in EXCLUDE_DIR_NAMES for part in rel.split('/')[:-1]):
        return True
    if name.startswith('unit-') and (name.endswith('.json') or name.endswith('.pending')):
        return True
    if rel.endswith(EXCLUDE_SUFFIXES):
        return True
    return False


def collect():
    files = []
    skipped = []
    for name in INCLUDE_FILES:
        if os.path.isfile(name):
            files.append(name.replace('\\', '/'))
    for base in INCLUDE_DIRS:
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIR_NAMES)
            for name in sorted(filenames):
                rel = os.path.relpath(os.path.join(dirpath, name), '.').replace('\\', '/')
                if excluded(rel, name):
                    skipped.append(rel)
                    continue
                files.append(rel)
    return sorted(set(files)), sorted(skipped)


files, skipped = collect()
os.makedirs(OUT_DIR, exist_ok=True)

entries = []
for rel in files:
    entries.append({
        'path': rel,
        'bytes': os.path.getsize(rel),
        'sha256': sha256(rel),
        'category': category_of(rel),
    })

counts = {}
total_bytes = 0
for item in entries:
    counts[item['category']] = counts.get(item['category'], 0) + 1
    total_bytes += item['bytes']

index = {
    'schema': 'ict-package-index-v1',
    'generatedAt': datetime.now(timezone(timedelta(hours=8))).isoformat(),
    'rootPrefix': ROOT_PREFIX,
    'note': 'This index does not list itself. The archive hash is recorded outside the archive.',
    'counts': {'files': len(entries), 'bytes': total_bytes, 'byCategory': counts},
    'exclusions': {
        'directories': sorted(EXCLUDE_DIR_NAMES),
        'paths': EXCLUDE_PATH_PREFIXES + EXCLUDE_PATH_GLOBS,
        'fileRule': 'unit-*.json / unit-*.json.pending at the workspace root (stray test output)',
        'skippedCount': len(skipped),
    },
    'files': entries,
}

index_path = os.path.join(OUT_DIR, 'PACKAGE_INDEX.json')
json.dump(index, open(index_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

read_first = f"""# 交付包说明（{STAMP}）

本包是工作区在 2026-10-25 19:25 的只读快照，用于交付与复核。

## 先读什么

1. `audit/latest_week9.md` —— 当前最新状态入口（任务计数、校验结果、未完成项、本地闭环状态）
2. `docs/backend/week9_readiness.json` —— 第9周台账（机器可读权威状态）
3. `docs/backend/local_closure_plan.md` —— 本地工程闭环方案（五条链与执行顺序）
4. `docs/backend/resource_plan_v2.md` —— 三项云资源具体方案（含成本与失败分支）
5. `docs/backend/resource_check_urls.md` —— 六项待确认事项的直达网址
6. `docs/backend/week10_plan.md` —— 第10周四支分支方案
7. `src/backend/deploy/README.md` —— 云端部署包说明（含外部终端四条验收命令）

## 本包包含

| 目录 | 内容 |
|---|---|
| `src/` | 源码（仓颉后端、Web Demo、鸿蒙 ArkTS、数据） |
| `docs/` | 计划、台账、调研、部署说明 |
| `audit/` | 全部审计记录与证据 |
| `artifacts/` | 历史交付物、云部署包、补充材料 |
| `AGENTS.md` | 项目工作约定 |

## 本包不包含（有意排除）

- `temp/`、`output/`、`.hvigor/`、`.playwright-cli/`、`.workbuddy-ai/`：临时与工具目录
- `node_modules/`：依赖目录，用 `src/web-demo/package-lock.json` 还原
- 历史交付包 `artifacts/backend/delivery_*`：避免包内套包
- 工作区根目录下的 `unit-*.json`：早期测试运行的散落输出
- 本包自身：避免递归

## 完整性校验

`PACKAGE_INDEX.json` 列出除自身外的每个文件的字节数与 SHA-256。压缩包的 SHA-256 记在包外的
`DELIVERY_INDEX.json` 与 `SHA256SUMS.txt` 中，不嵌入包内，避免自引用。

## 重要边界（不要读成已通过）

- 所有数据为开发期合成数据；**真实模型调用次数为 0**（`realG1Ran` 恒为 false，`G1_NOT_RUN`）
- **云端未部署**：无云主机、无公网 IP、无对象存储；外部终端访问未验证
- **设备未验证**：`hdc list targets` 为 `[Empty]`，通知/卡片/设备端回执均未执行
- 本地 HTTPS 入口与五环节端到端已在本机验证；本地结果不替代云端或设备结论
- 详见 `audit/latest_week9.md` 的验收对照与声明边界
"""
read_first_path = os.path.join(OUT_DIR, 'READ_FIRST.md')
open(read_first_path, 'w', encoding='utf-8').write(read_first)

# READ_FIRST.md is generated above the index, so the index can and must list it.
entries.append({
    'path': 'READ_FIRST.md',
    'bytes': os.path.getsize(read_first_path),
    'sha256': sha256(read_first_path),
    'category': 'root',
})
counts['root'] = counts.get('root', 0) + 1
total_bytes += os.path.getsize(read_first_path)
index['counts'] = {'files': len(entries), 'bytes': total_bytes, 'byCategory': counts}
index['files'] = entries
json.dump(index, open(index_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

zip_path = os.path.join(OUT_DIR, ZIP_NAME)

# Two generated files live on disk under OUT_DIR but belong at the package root.
generated = [
    (read_first_path, 'READ_FIRST.md'),
    (index_path, 'PACKAGE_INDEX.json'),
]
archive_members = [(rel, rel) for rel in files] + [(src, name) for src, name in generated]

with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for source, name in sorted(archive_members, key=lambda item: item[1]):
        info = zipfile.ZipInfo(f'{ROOT_PREFIX}/{name}', date_time=FIXED_TIME)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(source, 'rb') as handle:
            archive.writestr(info, handle.read())

zip_bytes = os.path.getsize(zip_path)
zip_sha = sha256(zip_path)

with zipfile.ZipFile(zip_path) as archive:
    names = archive.namelist()
    prefix = ROOT_PREFIX + '/'
    inner = sorted(name[len(prefix):] for name in names if name.startswith(prefix))
    expected = sorted(files + ['READ_FIRST.md', 'PACKAGE_INDEX.json'])
    source_of = {name: src for src, name in archive_members}
    mismatched = []
    for rel in inner:
        if rel not in expected:
            mismatched.append({'path': rel, 'problem': 'unexpected member'})
            continue
        data = archive.read(prefix + rel)
        digest = hashlib.sha256(data).hexdigest()
        if digest != sha256(source_of[rel]):
            mismatched.append({'path': rel, 'problem': 'hash differs from disk'})
    for rel in expected:
        if rel not in inner:
            mismatched.append({'path': rel, 'problem': 'missing member'})

delivery = {
    'schema': 'ict-delivery-index-v1',
    'generatedAt': datetime.now(timezone(timedelta(hours=8))).isoformat(),
    'archive': {'name': ZIP_NAME, 'bytes': zip_bytes, 'sha256': zip_sha, 'members': len(inner)},
    'content': {'files': len(entries), 'bytes': total_bytes, 'byCategory': counts},
    'readFirst': 'READ_FIRST.md',
    'packageIndex': 'PACKAGE_INDEX.json',
    'verification': {
        'membersExpected': len(expected),
        'membersFound': len(inner),
        'mismatches': mismatched,
        'status': 'passed' if not mismatched else 'failed',
    },
    'exclusions': index['exclusions'],
    'signed': False,
    'signatureNote': 'No independent signature. This is a self-produced delivery index.',
}
json.dump(delivery, open(os.path.join(OUT_DIR, 'DELIVERY_INDEX.json'), 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)
open(os.path.join(OUT_DIR, 'SHA256SUMS.txt'), 'w', encoding='utf-8').write(f'{zip_sha}  {ZIP_NAME}\n')

print(json.dumps({
    'zip': zip_path,
    'bytes': zip_bytes,
    'sha256': zip_sha,
    'members': len(inner),
    'files': len(entries),
    'verification': delivery['verification']['status'],
    'mismatches': len(mismatched),
    'skipped': len(skipped),
}, ensure_ascii=False, indent=2))
