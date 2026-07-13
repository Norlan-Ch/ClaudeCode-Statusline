#!/usr/bin/env bash
# ==============================================================================
# render.sh 的测试（集成测试，依赖本机的 google-chrome + Maple 字体 + ImageMagick identify）
# 契约：把 assets/ 下两张 SVG 源现渲染成同名 2x 高清 PNG
#   - 产物尺寸 = SVG 声明宽高 × 2（device-scale 2）
#   - 产物为合法 PNG，且内容非空白（渲染出彩色文本 → 颜色数足够多）
# ==============================================================================
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 脚本自身所在目录 = 仓库根
RENDER="$DIR/render.sh"
ASSETS="$DIR/assets"
pass=0; fail=0
ok() { echo "  ✓ $1"; pass=$((pass+1)); }
no() { echo "  ✗ $1"; fail=$((fail+1)); }

# 从 SVG 根元素解析声明宽高（根 <svg> 标签内各只有一个 width/height）
svg_dim() { # $1=svg 文件 -> 输出 "W H"
    local tag w h
    tag=$(tr '\n' ' ' < "$1" | sed -n 's/.*\(<svg[^>]*>\).*/\1/p')
    w=$(printf '%s' "$tag" | sed -n 's/.*width="\([0-9.]*\)".*/\1/p')
    h=$(printf '%s' "$tag" | sed -n 's/.*height="\([0-9.]*\)".*/\1/p')
    echo "$w $h"
}

echo "=== 前置依赖 ==="
command -v identify >/dev/null && ok "identify(ImageMagick) 可用" || { no "缺 identify，无法校验产物"; echo "结果：$pass 通过 / $fail 失败"; exit 1; }

echo "=== render.sh 存在且可执行 ==="
[ -f "$RENDER" ] && ok "render.sh 存在" || no "render.sh 不存在"
[ -x "$RENDER" ] && ok "render.sh 可执行" || no "render.sh 不可执行"

echo "=== 清理旧产物，确保由 render.sh 现渲染（no-op 脚本会因此失败）==="
rm -f "$ASSETS/statusline-main.png" "$ASSETS/statusline-subagent.png"

echo "=== 运行 render.sh ==="
if [ -x "$RENDER" ] && bash "$RENDER" >/tmp/render_test.out 2>&1; then
    ok "render.sh 退出码 0"
else
    no "render.sh 运行失败或不存在"
    [ -f /tmp/render_test.out ] && sed 's/^/    /' /tmp/render_test.out
fi

for name in statusline-main statusline-subagent; do
    svg="$ASSETS/$name.svg"; png="$ASSETS/$name.png"
    echo "=== 校验 $name.png ==="
    if [ -f "$png" ]; then ok "$name.png 已生成"; else no "$name.png 未生成"; continue; fi
    [ "$(identify -format '%m' "$png" 2>/dev/null)" = "PNG" ] && ok "是合法 PNG" || no "不是合法 PNG"
    read -r w h < <(svg_dim "$svg")
    exp="$((w*2))x$((h*2))"
    got=$(identify -format '%wx%h' "$png" 2>/dev/null)
    [ "$got" = "$exp" ] && ok "尺寸 $got = 2× SVG(${w}×${h})" || no "尺寸 $got ≠ 期望 $exp"
    k=$(identify -format '%k' "$png" 2>/dev/null)
    if [ "${k:-0}" -gt 100 ] 2>/dev/null; then ok "内容非空白（$k 种颜色）"; else no "疑似空白/渲染失败（颜色数=${k:-?}）"; fi
done

echo
echo "=== 结果：$pass 通过 / $fail 失败 ==="
[ "$fail" -eq 0 ]
