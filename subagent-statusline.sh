#!/usr/bin/env bash
# ==============================================================================
# Claude Code subagent 面板行渲染（方案 C·精简）
# 布局：状态点 · 名称 · 模型 · 上下文占用 · 运行时长
#   - 模型按档位上色（opus 紫 / sonnet 黄 / haiku 绿 / fable 七彩 / 其它品红），
#     颜色本身即成本信号；fable 逐字符赤橙黄绿青蓝紫循环
#   - 上下文占用 = tokenCount/contextWindowSize (百分比)，如 36K/200K (18%)；三档变色（<50 绿 / 50-79 黄 / >=80 红）
#     窗口未知（v2.1.205 前或未解析）时退化为纯 token 数
#   - 运行时长由 startTime(毫秒) 与当前时刻实时计算
# 输出协议：每行一个 JSON {"id":..,"content":..}
#   省略某 id → 保留系统默认渲染；content 给空串 → 隐藏该行
# 依赖：jq、GNU date（%s%3N 取毫秒）；无网络请求
# ==============================================================================

input=$(cat)
now_ms=$(date +%s%3N 2>/dev/null)   # 当前 Unix 毫秒（GNU date）

# ---------- ANSI 颜色 ----------
ESC=$'\e'; R="${ESC}[0m"; DIM="${ESC}[90m"
C_GREEN="${ESC}[32m"; C_YELLOW="${ESC}[33m"; C_RED="${ESC}[31m"; C_MAGENTA="${ESC}[35m"
# 档位色
C_OPUS="${ESC}[38;5;135m"   # 紫（最贵）
C_SONNET="${ESC}[33m"       # 黄（中）
C_HAIKU="${ESC}[32m"        # 绿（便宜/快）
# 七彩循环（赤橙黄绿青蓝紫，256 色索引，用于 fable）
RAINBOW=(196 208 226 46 51 27 129)

# 模型 ID → 档位色（非 fable）
tier_color() {
    case "$1" in
        *opus*)   printf '%s' "$C_OPUS" ;;
        *sonnet*) printf '%s' "$C_SONNET" ;;
        *haiku*)  printf '%s' "$C_HAIKU" ;;
        *)        printf '%s' "$C_MAGENTA" ;;   # 未知模型兜底
    esac
}

# 逐字符七彩上色（供 fable 使用）
rainbow_text() {
    local s="$1" out="" i ch idx n=${#RAINBOW[@]}
    for (( i=0; i<${#s}; i++ )); do
        ch="${s:i:1}"; idx=${RAINBOW[i % n]}
        out+="${ESC}[38;5;${idx}m${ch}"
    done
    printf '%s%s' "$out" "$R"
}

# 状态 → 彩色圆点
dot() {
    case "$1" in
        running|active|in_progress) printf '%s●%s' "$C_GREEN" "$R" ;;
        completed|done|success)     printf '%s●%s' "$DIM"     "$R" ;;
        failed|error|cancelled)     printf '%s●%s' "$C_RED"   "$R" ;;
        *)                          printf '%s○%s' "$DIM"     "$R" ;;
    esac
}

# 三档变色：<50 绿 / 50-79 黄 / >=80 红
color_pct() {
    local p="$1"
    if   [ "$p" -ge 80 ] 2>/dev/null; then printf '%s' "$C_RED"
    elif [ "$p" -ge 50 ] 2>/dev/null; then printf '%s' "$C_YELLOW"
    else printf '%s' "$C_GREEN"; fi
}

# 模型 ID 美化：去 claude- 前缀与尾部 -YYYYMMDD 日期，保留 [1m] 之类后缀
pretty() {
    local m="${1#claude-}"
    [[ "$m" =~ ^(.*)-[0-9]{8}(\[.*\])?$ ]] && m="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    printf '%s' "$m"
}

# 渲染模型段：fable 走七彩，其余走档位单色
model_render() {
    local m="$1" p; p=$(pretty "$m")
    case "$m" in
        *fable*) rainbow_text "$p" ;;
        *)       printf '%s%s%s' "$(tier_color "$m")" "$p" "$R" ;;
    esac
}

# 毫秒时长 → 人类可读（42s / 2m 18s / 1h 05m）
fmt_dur() {
    jq -nr --argjson ms "$1" '
        ($ms/1000|floor) as $s |
        if   $s < 60   then ($s|tostring)+"s"
        elif $s < 3600 then (($s/60|floor)|tostring)+"m "+(($s%60)|tostring)+"s"
        else (($s/3600|floor)|tostring)+"h "+((($s%3600)/60|floor)|tostring)+"m" end' 2>/dev/null
}

# token 数 → K/M 缩写（0 原样，36000→36K，1234567→1.2M）
fmt_tok() {
    jq -nr --argjson n "$1" '
        if   $n >= 1000000 then ((($n/100000|round)/10)|tostring)+"M"
        elif $n >= 1000    then (($n/1000|round)|tostring)+"K"
        else ($n|tostring) end' 2>/dev/null
}

# ---------- 逐 task 渲染 ----------
printf '%s' "$input" | jq -c '.tasks[]?' 2>/dev/null | while IFS= read -r t; do
    id=$(jq -r '.id // empty' <<<"$t"); [ -z "$id" ] && continue
    name=$(jq -r '.name // .label // .description // .type // "agent"' <<<"$t")
    st=$(jq -r '.status // empty' <<<"$t")
    model=$(jq -r '.model // empty' <<<"$t")             # v2.1.205+，可能缺省
    cs=$(jq -r '.contextWindowSize // empty' <<<"$t")    # v2.1.205+，可能缺省
    start=$(jq -r '.startTime // empty' <<<"$t")         # 毫秒
    tok=$(jq -r '.tokenCount // empty' <<<"$t")

    seg="$(dot "$st") ${name}"

    # 模型段（档位上色 / fable 七彩；未解析则整段隐藏）
    [ -n "$model" ] && seg="${seg}${DIM} · ${R}$(model_render "$model")"

    # 上下文占用段：token/window (占用%)，三档变色；窗口未知时退化为纯 token
    if [ -n "$cs" ] && [ "$cs" != 0 ] && [ -n "$tok" ]; then
        pct=$(jq -nr --argjson t "$tok" --argjson s "$cs" '(($t/$s*100)|round)' 2>/dev/null)
        if [ -n "$pct" ]; then
            seg="${seg}${DIM} · ${R}$(color_pct "$pct")$(fmt_tok "$tok")/$(fmt_tok "$cs") (${pct}%)${R}"
        fi
    elif [ -n "$tok" ]; then
        seg="${seg}${DIM} · ${R}$(fmt_tok "$tok")"
    fi

    # 运行时长段（startTime 毫秒，与当前时刻求差）
    if [ -n "$start" ] && [[ "$now_ms" =~ ^[0-9]+$ ]]; then
        dms=$(( now_ms - start )); [ "$dms" -lt 0 ] && dms=0
        d=$(fmt_dur "$dms"); [ -n "$d" ] && seg="${seg}${DIM} · ${R}${d}"
    fi

    # jq 负责把 content 里的 ESC 安全转义为
    jq -nc --arg id "$id" --arg content "$seg" '{id:$id, content:$content}'
done
