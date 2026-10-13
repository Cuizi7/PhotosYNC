#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
derived=""
output=""
interactive=0
probe=0
scenario="syncing"
appearance="light"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data) derived="$2"; shift 2 ;;
    --output-dir) output="$2"; shift 2 ;;
    --interactive) interactive=1; shift ;;
    --probe) probe=1; shift ;;
    --scenario) scenario="$2"; shift 2 ;;
    --appearance) appearance="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$derived" && -n "$output" ]] || { echo "--derived-data and --output-dir are required" >&2; exit 2; }
[[ "$appearance" == light || "$appearance" == dark ]] || { echo "Invalid appearance" >&2; exit 2; }
[[ "$interactive" != 1 || "$probe" != 1 ]] || { echo "Choose --interactive or --probe" >&2; exit 2; }
products="$derived/Build/Products/Debug"
[[ -f "$products/PhotoSyncCore.framework/PhotoSyncCore" && -f "$products/PhotosYNC.app/Contents/Info.plist" ]] || {
  echo "Build-for-testing Debug Core and app Info.plist are required" >&2; exit 1;
}
[[ ! -e "$output" ]] || { echo "Output must be a fresh directory: $output" >&2; exit 1; }
mkdir -p "$output"
output="$(cd "$output" && pwd)"
bundle="$output/PhotosYNC UI Review.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks"
ditto "$products/PhotoSyncCore.framework" "$bundle/Contents/Frameworks/PhotoSyncCore.framework"
cp "$products/PhotosYNC.app/Contents/Info.plist" "$bundle/Contents/Info.plist"
python3 - "$bundle/Contents/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f: info = plistlib.load(f)
info.update(CFBundleExecutable='UIReviewHost', CFBundleIdentifier='local.photosync.ui-review',
            CFBundleName='PhotosYNC UI Review', CFBundleDisplayName='PhotosYNC UI Review', LSUIElement=True)
# This host has no app icon resource stage and never asks for system permission.
for key in ('CFBundleIconFile', 'CFBundleIconName', 'NSPrincipalClass'):
    info.pop(key, None)
with open(p, 'wb') as f: plistlib.dump(info, f)
PY
sources=()
while IFS= read -r file; do
  [[ "$file" == */PhotoSyncApp.swift ]] || sources+=("$file")
done < <(rg --files "$repo/Sources/PhotoSyncApp" -g '*.swift' | sort)
sources+=("$repo/Tests/UIReview/ReviewFixtures.swift" "$repo/Tests/UIReview/ReviewHost.swift")
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  -module-name UIReviewHost -F "$products" -framework PhotoSyncCore \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "${sources[@]}" -o "$bundle/Contents/MacOS/UIReviewHost" > "$output/compile.log" 2>&1
codesign --force --sign - --timestamp=none "$bundle/Contents/Frameworks/PhotoSyncCore.framework" > "$output/sign.log" 2>&1
codesign --force --sign - --timestamp=none "$bundle" >> "$output/sign.log" 2>&1
python3 - "$repo" "$output" "$products" "${sources[@]}" <<'PY'
import hashlib, json, pathlib, subprocess, sys
repo, output, products = map(pathlib.Path, sys.argv[1:4])
def command(*args):
    return subprocess.check_output(args, cwd=repo, text=True).strip()
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
files = [pathlib.Path(p) for p in sys.argv[4:]]
metadata = dict(sourceCommit=command('git', 'rev-parse', 'HEAD'),
                sourceDiff=command('git', 'diff', '--stat'),
                sourceStatus=command('git', 'status', '--short'),
                os=command('sw_vers'), xcode=command('xcodebuild', '-version'),
                swift=command('xcrun', 'swift', '--version'),
                compiledFiles=[dict(path=str(p.relative_to(repo)), sha256=digest(p)) for p in files],
                coreFrameworkSHA256=digest(products/'PhotoSyncCore.framework/PhotoSyncCore'),
                appInfoSHA256=digest(products/'PhotosYNC.app/Contents/Info.plist'),
                derivedData=str(products.parent.parent.parent),
                fixtureIsolation='UUID temporary SQLite; source descriptions only; no engine/gateway/bootstrap/tick')
(output/'source.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
PY
if [[ "$interactive" == 1 ]]; then
  exec "$bundle/Contents/MacOS/UIReviewHost" --output-dir "$output" --interactive --scenario "$scenario" --appearance "$appearance"
fi
if [[ "$probe" == 1 ]]; then
  "$bundle/Contents/MacOS/UIReviewHost" --output-dir "$output" --probe > "$output/capture.log" 2>&1
  python3 - "$output" <<'PY'
import html, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
m = json.loads((out/'probe-manifest.json').read_text())
parts = ['<!doctype html><html lang="zh"><meta charset="utf-8"><title>原生交互候选证据</title>',
 '<style>body{font:15px system-ui;margin:24px}.light{background:#f5f5f5;color:#222}.dark{background:#202020;color:white}section{padding:20px;margin:20px 0}pre{white-space:pre-wrap}img{max-width:100%;height:auto}figure{margin:10px 0}</style>',
 '<h1>PhotosYNC · 原生交互候选证据 · 等待用户验收</h1>',
 '<p>仅本测试 host 的窗口。cacheDisplay 透明底在相应明/暗背景展示，不改 PNG；WindowServer 图片来自已有录屏许可下的 own-window 定向 screencapture，可能包含其父宿主组合。</p>',
 '<p><a href="probe-manifest.json">原始观测清单</a> · <a href="source.json">源码与环境</a></p>']
for probe in m['interactions']:
    parts.append('<section class="'+probe['appearance']+'"><h2>'+html.escape(probe['scenario']+' / '+probe['appearance'])+'</h2>')
    for presentation in probe.get('presentations', []):
        for item in [presentation, presentation.get('compositor', {})]:
            if item.get('file') and (out/item['file']).is_file():
                f=html.escape(item['file'])
                parts.append('<figure><a href="'+f+'">原始 PNG</a><br><img src="'+f+'"></figure>')
    parts.append('<pre>'+html.escape(json.dumps(probe,ensure_ascii=False,indent=2))+'</pre></section>')
parts.append('</html>')
(out/'index.html').write_text('\n'.join(parts))
PY
  exit 0
fi
"$bundle/Contents/MacOS/UIReviewHost" --output-dir "$output" > "$output/capture.log" 2>&1
python3 - "$output" <<'PY'
import html, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
m = json.loads((out/'manifest.json').read_text())
captures = m['captures']
scenarios = ['syncing','analyzing','preparing','icloud','paused','pausing','completed','offline',
             'fileIssue','unauthorized','unknown','summaryLoading','summaryStale','empty','single','many','longLeaf']
expected = {(s,a,v) for s in scenarios for a in ('light','dark') for v in ('menu','settings')}
expected |= {('many', a, 'settings-bottom') for a in ('light','dark')}
actual = {(c['scenario'],c['appearance'],c['surface']) for c in captures}
if len(captures) != 70 or actual != expected:
    raise SystemExit('Missing/duplicate matrix entries')
for c in captures:
    p = out/c['file']
    if not p.is_file() or p.stat().st_size < 512: raise SystemExit('Missing/empty PNG: '+str(p))
    width = 320 if c['surface']=='menu' else 600
    if abs(c['logicalWidth']-width)>1 or not 100<c['logicalHeight']<=681:
        raise SystemExit('Unexpected dimensions: '+str(c))
esc = html.escape
parts = ['<!doctype html><html lang="zh"><meta charset="utf-8"><title>PhotosYNC 原生 UI 待验收</title>',
 '<style>body{font:15px system-ui;margin:24px;background:#eceef0;color:#222}section{margin:30px 0;padding:20px;background:white;border-radius:12px}.pair{display:flex;gap:24px;align-items:start;flex-wrap:wrap}figure{margin:12px 0}img{display:block;max-width:100%;box-shadow:0 1px 8px #8888}pre{white-space:pre-wrap;font-size:12px}a{color:#175ba4}</style>',
 '<h1>PhotosYNC · 真实编译视图 · 候选证据 · 等待用户验收</h1>',
 '<p>17 场景 × 浅/深外观 × 菜单/设置 + 2 张设置底部，共 70 张原始 PNG。系统开关在隔离 injected 模型中禁用。</p>',
 '<p>菜单为真实 StatusMenu 的离屏原生绘制；不是系统 MenuBarExtra 弹出截图。图片按逻辑尺寸展示，原图链接保留像素。</p>',
 '<p><a href="manifest.json">完整清单与原生交互结果</a> · <a href="source.json">源码/环境/编译文件 SHA256</a></p>',
 '<pre>'+esc(json.dumps({k:m[k] for k in ('sourceCommit','sourceDiff','sourceStatus','os','xcode','hostBundle')},ensure_ascii=False,indent=2))+'</pre>',
 '<h2>瞬态交互</h2><p>以下为隐藏、非 key 宿主的实际本进程尝试；unverified 项需用户控制测试宿主补验。没有静态拼接浮层。</p>',
 '<pre>'+esc(json.dumps(m['interactions'],ensure_ascii=False,indent=2))+'</pre>']
for s in scenarios:
    parts.append('<section><h2>'+esc(s)+'</h2>')
    for a in ('light','dark'):
        parts.append('<h3>'+a+'</h3><div class="pair">')
        for c in captures:
            if c['scenario']==s and c['appearance']==a:
                f=esc(c['file']);w=c['logicalWidth'];h=c['logicalHeight']
                parts.append(f'<figure><figcaption>{esc(c["surface"])} · {w:g}×{h:g}pt · <a href="{f}">原始 PNG</a></figcaption><img src="{f}" width="{w:g}" height="{h:g}"></figure>')
        parts.append('</div>')
    parts.append('</section>')
parts.append('</html>')
(out/'index.html').write_text('\n'.join(parts))
print('Validated 70-image matrix; gallery: '+str(out/'index.html'))
PY
