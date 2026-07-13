#!/usr/bin/env bash
# ==============================================================================
# render.sh —— 把 assets/ 下的 SVG 源渲染成同名 2x 高清 PNG（供 README 展示）
#
# 为什么要「烤成 PNG」：README 里的 SVG 由访问者浏览器现渲染、用访问者本机字体，
# 多数人没装 Maple → 看到 fallback。故本机（装了 Maple）渲染成位图，把 Maple 烤进图里，
# 处处一致、零字体依赖。emoji 同时挂载彩色 emoji 字体保证不出豆腐块。
#
# 契约：产物尺寸 = SVG 声明宽高 × 2（headless Chrome，device-scale 2）
# 依赖：google-chrome（或 chromium）、Maple Mono 字体、fontconfig；无网络请求
# 用法：bash render.sh            # 渲染 assets 下全部 *.svg
# ==============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 脚本自身所在目录 = 仓库根，clone 到任意位置都自适应
ASSETS="$DIR/assets"

# ---------- 1. 定位 headless 浏览器 ----------
CHROME=""
for c in google-chrome-stable google-chrome chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then CHROME="$c"; break; fi
done
[ -n "$CHROME" ] || { echo "render.sh: 未找到 google-chrome / chromium" >&2; exit 1; }

# ---------- 2. 定位 Maple 字体（缺则硬失败：没有 Maple 就无法把 Maple 烤进图）----------
MAPLE=""
for f in \
    "$HOME/.local/share/fonts/MapleMonoNormal-NF-CN-Regular.ttf" \
    "$HOME/.local/share/fonts/MapleMono-NF-CN-Regular.ttf" \
    /mnt/c/Windows/Fonts/MapleMonoNormal-CN-Regular.ttf \
    /mnt/c/Windows/Fonts/MapleMono-NF-CN-Regular.ttf; do
    [ -f "$f" ] && { MAPLE="$f"; break; }
done
# 兜底：让 fontconfig 解析任意已安装的 Maple Mono 家族
if [ -z "$MAPLE" ] && command -v fc-match >/dev/null 2>&1; then
    cand=$(fc-match -f '%{file}' 'Maple Mono' 2>/dev/null || true)
    case "$cand" in *[Mm]aple*) MAPLE="$cand" ;; esac
fi
[ -n "$MAPLE" ] || { echo "render.sh: 未找到 Maple Mono 字体，无法烤入 Maple" >&2; exit 1; }

# ---------- 3. 定位彩色 emoji 字体（缺则告警但继续；仅影响 emoji 呈现）----------
EMOJI=""
for f in \
    /mnt/c/Windows/Fonts/seguiemj.ttf \
    /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf \
    /usr/share/fonts/noto/NotoColorEmoji.ttf \
    /usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf; do
    [ -f "$f" ] && { EMOJI="$f"; break; }
done
if [ -z "$EMOJI" ] && command -v fc-match >/dev/null 2>&1; then
    cand=$(fc-match -f '%{file}' 'emoji' 2>/dev/null || true)
    case "$cand" in *[Ee]moji*) EMOJI="$cand" ;; esac
fi
[ -n "$EMOJI" ] || echo "render.sh: 警告——未找到彩色 emoji 字体，emoji 可能显示为空框" >&2

# ---------- 4. 临时字体环境（只喂 Maple + emoji，不污染用户字体目录）----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fonts"
cp -f "$MAPLE" "$TMP/fonts/"
[ -n "$EMOJI" ] && cp -f "$EMOJI" "$TMP/fonts/"
export XDG_DATA_HOME="$TMP" XDG_CACHE_HOME="$TMP/cache"
fc-cache -f "$TMP/fonts" >/dev/null 2>&1 || true

echo "render.sh: chrome=$CHROME"
echo "render.sh: maple=$(basename "$MAPLE")"
if [ -n "$EMOJI" ]; then echo "render.sh: emoji=$(basename "$EMOJI")"; else echo "render.sh: emoji=（无）"; fi

# ---------- 5. 逐张 SVG 渲染成 2x PNG ----------
# 从根 <svg> 标签解析声明宽高（各只有一个），窗口即设为该尺寸、device-scale 2 → 恰好 2x
render_one() {
    local svg="$1" png="${1%.svg}.png" tag w h
    tag=$(tr '\n' ' ' < "$svg" | sed -n 's/.*\(<svg[^>]*>\).*/\1/p')
    w=$(printf '%s' "$tag" | sed -n 's/.*width="\([0-9.]*\)".*/\1/p')
    h=$(printf '%s' "$tag" | sed -n 's/.*height="\([0-9.]*\)".*/\1/p')
    if [ -z "$w" ] || [ -z "$h" ]; then
        echo "render.sh: 无法解析 $(basename "$svg") 的宽高，跳过" >&2; return 1
    fi
    "$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
        --force-device-scale-factor=2 --window-size="$w,$h" \
        --default-background-color=00000000 \
        --user-data-dir="$TMP/chrome" \
        --screenshot="$png" "$svg" >/dev/null 2>&1 || true
    [ -f "$png" ] || { echo "render.sh: $(basename "$png") 渲染失败" >&2; return 1; }
    echo "render.sh: 生成 $(basename "$png")  ($((w*2))x$((h*2)))"
}

shopt -s nullglob
svgs=("$ASSETS"/*.svg)
[ "${#svgs[@]}" -gt 0 ] || { echo "render.sh: assets/ 下没有 *.svg" >&2; exit 1; }
for svg in "${svgs[@]}"; do render_one "$svg"; done
echo "render.sh: 完成。"
