#!/usr/bin/env bash
# ==============================================================================
# Claude Code 自定义 statusline 脚本
# 布局（三行）：
#   第1行：路径 | Git分支
#   第2行：模型(Effort) | Token用量 | 5h配额 | 周配额
#   第3行：会话时长 | 内存 | 缓存过期时刻 | 花费
# 依赖：jq、git（无网络请求）；另读取 /proc/meminfo 与 transcript 末尾若干行
# 设计原则：任一区域数据缺失时该区域（含前导分隔符）整段隐藏；
#           某一行全部区域缺失时该行不输出（不留空行），绝不阻塞渲染
# ==============================================================================

# ---------- 颜色定义（ANSI 转义序列，最终统一用 printf %b 解释） ----------
C_RESET='\e[0m'
C_SEP='\e[90m'      # 分隔符：亮灰/亮黑
C_PATH='\e[38;5;208m' # 路径：橙色（256 色，与全部现用色区隔）
C_GREEN='\e[32m'    # 绿色：用量低
C_YELLOW='\e[33m'   # 黄色：Git dirty / 用量中
C_RED='\e[31m'      # 红色：用量高
C_MODEL='\e[35m'    # 模型：品红色
C_GITCLEAN='\e[94m' # 亮蓝：Git 干净分支（与用量绿区别）

# ---------- 第3行段前缀 emoji ----------
# 均为 Unicode 6.0 emoji-presentation 字符：默认彩色呈现、无需 VS16(U+FE0F)、
# 在等宽终端里宽度恒为 2 列，渲染稳定（避免 ⏱/⏲ 这类需 VS16、宽度不定的字形）。
E_UP='🕐'       # 会话时长：钟面
E_RAM='💾'      # 内存：存储盘
E_CACHE='⏳'    # 缓存过期：沙漏（倒计时/即将失效；刻意避开日历 emoji 以免误读为日期）
E_COST='💰'     # 花费：钱袋

# ---------- 工具函数 ----------

# 数字格式化：
#   n >= 999,500 -> 换算为 M，保留一位小数（如 1234567 -> "1.2M"，1000000 -> "1.0M"）
#                   999,500 起进 M 档，是为了让 K 档四舍五入到 1000 时能正确进位为 "1.0M"
#                   （即 999,500~999,999 -> "1.0M"；999,499 及以下仍是 "999K"）
#   n >= 1,000   -> 换算为 K，四舍五入取整（如 5000 -> "5K"）
#   n < 1,000    -> 原始数字
# 全程用 jq 做数值计算，不依赖 awk/bc
format_k() {
    local n="$1"
    jq -nr --argjson n "$n" '
        if $n >= 999500 then
            (($n/100000|round)/10) as $m |
            (if $m == ($m|floor) then ($m|tostring)+".0" else ($m|tostring) end) + "M"
        elif $n >= 1000 then
            (($n/1000)|round|tostring)+"K"
        else
            ($n|tostring)
        end
    ' 2>/dev/null
}

# 对（可能是浮点数的）数值四舍五入取整，返回整数字符串；用 jq 而非 awk/bc
round_num() {
    local n="$1"
    jq -nr --argjson n "$n" '($n | round | tostring)' 2>/dev/null
}

# 三档变色：<50 绿，50-79 黄，>=80 红。输入非法数字时兜底为绿色
color_for_pct() {
    local p="$1"
    if [ "$p" -ge 80 ] 2>/dev/null; then
        printf '%s' "$C_RED"
    elif [ "$p" -ge 50 ] 2>/dev/null; then
        printf '%s' "$C_YELLOW"
    else
        printf '%s' "$C_GREEN"
    fi
}

# 将纯数字（unix 秒）或 ISO8601 时间字符串统一转换为 unix 秒；失败返回空
to_epoch() {
    local v="$1"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s' "$v"
    else
        date -d "$v" +%s 2>/dev/null
    fi
}

# 将 kB（KiB）格式化为 GiB 字符串：>=10 取整（如 "16G"），<10 保留一位小数（如 "7.0G"）
fmt_gib() {
    local kb="$1"
    jq -nr --argjson kb "$kb" '
        ($kb/1048576) as $g |
        (if $g >= 10 then
            ($g|round|tostring)
        else
            (($g*10|round)/10) as $r |
            (if $r == ($r|floor) then ($r|tostring)+".0" else ($r|tostring) end)
        end) + "G"
    ' 2>/dev/null
}

# 格式化美元金额：>=1 两位小数，>=0.1 三位，>0 四位，<=0 显示 $0.00；
# 用 jq 判定小数位、printf 补零（printf 为 bash 内建，不算外部依赖）
cost_fmt() {
    local c="$1"
    local digits
    digits=$(jq -nr --argjson c "$c" 'if $c <= 0 then 2 elif $c >= 1 then 2 elif $c >= 0.1 then 3 else 4 end' 2>/dev/null)
    [[ "$digits" =~ ^[0-9]+$ ]] || return 1
    printf '$%.*f' "$digits" "$c" 2>/dev/null
}

# ---------- 读取 stdin（只读一次，后续用 jq 反复提取，避免重复读流） ----------
input=$(cat)

# stdin 是否携带 cost 对象（供调试确认当前 CLI 版本是否供数）
has_cost=$(printf '%s' "$input" | jq -r 'if .cost != null then "true" else "false" end' 2>/dev/null)

line1_segments=()   # 第1行：路径、Git分支
line2_segments=()   # 第2行：模型、Token用量、Usage配额
line3_segments=()   # 第3行：会话时长、内存、缓存过期时刻、花费
rendered_names=()   # 调试标签：path/git/model/token/quota/up/ram/cache/cost

# ================= 1. 路径区域：青色，home 缩写为 ~，不截断 =================
cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

display_path="$cwd"
if [ -n "$HOME" ] && [ -n "$cwd" ]; then
    if [ "$cwd" = "$HOME" ]; then
        display_path="~"
    elif [ "${cwd#"$HOME"/}" != "$cwd" ]; then
        display_path="~/${cwd#"$HOME"/}"
    fi
fi

if [ -n "$display_path" ]; then
    line1_segments+=("${C_PATH}${display_path}${C_RESET}")
    rendered_names+=("path")
fi

# ================= 2. Git 分支区域 =================
# 干净：绿色；dirty（含 untracked）：黄色 + 尾部 "*"；detached HEAD：7 位短 hash；非仓库：整段隐藏
git_dir="${cwd:-$PWD}"
if git -C "$git_dir" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch_name=$(git -C "$git_dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$branch_name" ] || [ "$branch_name" = "HEAD" ]; then
        # detached HEAD：使用 7 位短 commit hash
        branch_name=$(git -C "$git_dir" --no-optional-locks rev-parse --short=7 HEAD 2>/dev/null)
        if [ -z "$branch_name" ]; then
            # 零提交仓库（unborn branch）：HEAD 尚未诞生，rev-parse HEAD 会失败，
            # 改用 symbolic-ref 取尚未诞生的分支名（如 main/master）
            branch_name=$(git -C "$git_dir" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
        fi
    fi
    if [ -n "$branch_name" ]; then
        # dirty 文件总数（含未跟踪）：porcelain 每行一个文件；干净则只显示绿色分支名不带数字
        git_porcelain=$(git -C "$git_dir" --no-optional-locks status --porcelain 2>/dev/null)
        if [ -n "$git_porcelain" ]; then
            git_dirty_count=$(printf '%s\n' "$git_porcelain" | grep -c '^')
            line1_segments+=("${C_YELLOW}${branch_name} *${git_dirty_count}${C_RESET}")
        else
            line1_segments+=("${C_GITCLEAN}${branch_name}${C_RESET}")
        fi
        rendered_names+=("git")
    fi
fi

# ================= 3. 模型 (Effort) 区域：品红色 =================
model_name=$(printf '%s' "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
effort_level=$(printf '%s' "$input" | jq -r '.effort.level // empty' 2>/dev/null)

# 1M context 变体后缀直接去除（token 段的 1.0M 窗口已表明 1M 上下文，无需在模型名重复标记）
model_name="${model_name/ (1M context)/}"

effort_abbr=""
case "$effort_level" in
    low) effort_abbr="Low" ;;
    medium) effort_abbr="Med" ;;
    high) effort_abbr="High" ;;
    xhigh) effort_abbr="XHigh" ;;
    max) effort_abbr="Max" ;;
esac

if [ -n "$model_name" ]; then
    if [ -n "$effort_abbr" ]; then
        line2_segments+=("${C_MODEL}${model_name} (${effort_abbr})${C_RESET}")
    else
        line2_segments+=("${C_MODEL}${model_name}${C_RESET}")
    fi
    rendered_names+=("model")
fi

# ================= 4. Token 用量区域 =================
# 优先使用新版 stdin 提供的 context_window 字段；缺失时兜底解析 transcript 最后一条 usage
ctx_tokens=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // empty' 2>/dev/null)
ctx_size=$(printf '%s' "$input" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
ctx_pct_raw=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)

if [ -z "$ctx_tokens" ] || [ -z "$ctx_size" ]; then
    ctx_tokens=""
    ctx_size=""
    ctx_pct_raw=""
    transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        last_usage=$(jq -c 'select(.type=="assistant" and .message.usage != null) | .message.usage' \
            "$transcript_path" 2>/dev/null | tail -n 1)
        if [ -n "$last_usage" ]; then
            ctx_tokens=$(printf '%s' "$last_usage" | jq -r \
                '((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' \
                2>/dev/null)
            # 无法获知真实窗口上限时，使用当前 Claude 模型的默认上下文窗口兜底
            ctx_size=200000
        fi
    fi
fi

if [ -n "$ctx_tokens" ] && [ -n "$ctx_size" ] && [ "$ctx_size" != "0" ]; then
    if [ -n "$ctx_pct_raw" ]; then
        ctx_pct=$(round_num "$ctx_pct_raw")
    else
        ctx_pct=$(jq -nr --argjson t "$ctx_tokens" --argjson s "$ctx_size" \
            '(($t/$s*100)|round|tostring)' 2>/dev/null)
    fi
    if [ -n "$ctx_pct" ]; then
        token_color=$(color_for_pct "$ctx_pct")
        line2_segments+=("${token_color}$(format_k "$ctx_tokens")/$(format_k "$ctx_size") (${ctx_pct}%)${C_RESET}")
        rendered_names+=("token")
    fi
fi

# ================= 5. Usage 配额区域 =================
# 计划名来自本地 OAuth 凭据；5 小时窗口用量直接取 stdin 自带的 rate_limits.five_hour
#（无网络请求、无缓存）。stdin 无该字段时（旧版 CLI 降级）配额区域整段隐藏。
credentials_file="$HOME/.claude/.credentials.json"

plan_raw=""
[ -f "$credentials_file" ] && plan_raw=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$credentials_file" 2>/dev/null)

plan_name=""
case "$plan_raw" in
    pro) plan_name="Pro" ;;
    max) plan_name="Max" ;;
    team) plan_name="Team" ;;
    enterprise) plan_name="Enterprise" ;;
    "") plan_name="" ;;
    *) plan_name="$(printf '%s' "${plan_raw^}")" ;;
esac

# 调试字段
quota_source="hidden"

# 直接读取 stdin 自带的 5 小时窗口限速数据
five_pct_raw=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
five_reset_raw=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty' 2>/dev/null)

if [ -n "$plan_name" ] && [ -n "$five_pct_raw" ]; then
    quota_source="stdin_rate_limits"
    quota_pct=$(round_num "$five_pct_raw")
    if [ -n "$quota_pct" ]; then
        quota_color=$(color_for_pct "$quota_pct")
        quota_str="${plan_name} ${quota_pct}%"
        if [ -n "$five_reset_raw" ]; then
            reset_epoch=$(to_epoch "$five_reset_raw")
            if [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
                now_ts2=$(date +%s)
                remain=$(( reset_epoch - now_ts2 ))
                if [ "$remain" -gt 0 ]; then
                    remain_hr=$(( remain / 3600 ))
                    remain_min=$(( (remain % 3600) / 60 ))
                    if [ "$remain_hr" -ge 1 ]; then
                        quota_str="${quota_str} (${remain_hr}h ${remain_min}m / 5h)"
                    else
                        # 不足 1 小时：省略小时位，只显示分钟
                        quota_str="${quota_str} (${remain_min}m / 5h)"
                    fi
                fi
            fi
        fi
        line2_segments+=("${quota_color}${quota_str}${C_RESET}")
        rendered_names+=("quota")
    fi
fi

# ---- 7 天（周）窗口用量：同源 stdin 的 rate_limits.seven_day，标签 "Week" ----
# 字段与 five_hour 完全一致（used_percentage / resets_at）；仅 Pro/Max 且首个 API
# 响应后出现，可独立于 five_hour 缺失，故用 // empty 兜底。gate 与 5h 对称（需 plan_name）。
seven_pct_raw=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)
seven_reset_raw=$(printf '%s' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty' 2>/dev/null)

if [ -n "$plan_name" ] && [ -n "$seven_pct_raw" ]; then
    week_pct=$(round_num "$seven_pct_raw")
    if [ -n "$week_pct" ]; then
        week_color=$(color_for_pct "$week_pct")
        week_str="Week ${week_pct}%"
        if [ -n "$seven_reset_raw" ]; then
            week_reset_epoch=$(to_epoch "$seven_reset_raw")
            if [[ "$week_reset_epoch" =~ ^[0-9]+$ ]]; then
                week_now=$(date +%s)
                week_remain=$(( week_reset_epoch - week_now ))
                if [ "$week_remain" -gt 0 ]; then
                    week_d=$(( week_remain / 86400 ))
                    week_h=$(( (week_remain % 86400) / 3600 ))
                    week_m=$(( (week_remain % 3600) / 60 ))
                    if [ "$week_d" -ge 1 ]; then
                        week_left="${week_d}d ${week_h}h"
                    elif [ "$week_h" -ge 1 ]; then
                        week_left="${week_h}h ${week_m}m"
                    else
                        week_left="${week_m}m"
                    fi
                    # 绝对重置时刻：星期缩写 + 24h 时钟；强制 C locale 保证英文 Fri/Mon（否则随系统语言可能出中文）
                    week_reset_at=$(LC_ALL=C date -d "@${week_reset_epoch}" '+%a %H:%M' 2>/dev/null)
                    if [ -n "$week_reset_at" ]; then
                        week_str="${week_str} (${week_left} / ${week_reset_at})"
                    else
                        week_str="${week_str} (${week_left})"
                    fi
                fi
            fi
        fi
        line2_segments+=("${week_color}${week_str}${C_RESET}")
        rendered_names+=("week")
    fi
fi

# ================= 6. 会话时长区域（第3行）：默认前景色 =================
# 数据源：stdin 的 cost.total_duration_ms（会话累计 wall-clock 毫秒）
dur_ms=$(printf '%s' "$input" | jq -r '.cost.total_duration_ms // empty' 2>/dev/null)
if [[ "$dur_ms" =~ ^[0-9]+$ ]]; then
    dur_str=$(jq -nr --argjson ms "$dur_ms" '
        ($ms/60000|floor) as $m |
        if $m < 1 then "<1m"
        elif $m < 60 then ($m|tostring)+"m"
        else (($m/60|floor)|tostring)+"h "+(($m%60)|tostring)+"m"
        end
    ' 2>/dev/null)
    if [ -n "$dur_str" ]; then
        line3_segments+=("${E_UP} Up ${dur_str}")
        rendered_names+=("up")
    fi
fi

# ================= 7. 内存区域（第3行）：默认前景色 =================
# 系统整体内存：读 /proc/meminfo 的 MemTotal / MemAvailable（单位 kB）
if [ -r /proc/meminfo ]; then
    mem_total_kb=$(grep -m1 '^MemTotal:' /proc/meminfo 2>/dev/null | grep -oE '[0-9]+' | head -n1)
    mem_avail_kb=$(grep -m1 '^MemAvailable:' /proc/meminfo 2>/dev/null | grep -oE '[0-9]+' | head -n1)
    if [[ "$mem_total_kb" =~ ^[0-9]+$ ]] && [[ "$mem_avail_kb" =~ ^[0-9]+$ ]] && [ "$mem_total_kb" -gt 0 ]; then
        mem_pct=$(jq -nr --argjson t "$mem_total_kb" --argjson a "$mem_avail_kb" \
            '((($t-$a)/$t)*100)|round|tostring' 2>/dev/null)
        mem_used_str=$(fmt_gib $(( mem_total_kb - mem_avail_kb )))
        mem_total_str=$(fmt_gib "$mem_total_kb")
        if [ -n "$mem_pct" ] && [ -n "$mem_used_str" ] && [ -n "$mem_total_str" ]; then
            # 内存占用三档变色（复用 color_for_pct：<50 绿 / 50-79 黄 / >=80 红），与第2行配色一致
            ram_color=$(color_for_pct "$mem_pct")
            line3_segments+=("${ram_color}${E_RAM} RAM ${mem_pct}% (${mem_used_str}/${mem_total_str})${C_RESET}")
            rendered_names+=("ram")
        fi
    fi
fi

# ================= 8. 缓存过期时刻区域（第3行）=================
# 显示 prompt cache 将被丢弃的"本地绝对时刻"（而非相对倒计时，从而无需定时刷新）。
# 起算点：transcript 末尾若干行里最后一条 assistant 的 timestamp。
# TTL 动态判定：最近一条 cache_creation 若 ephemeral_1h>0 -> 3600s，否则 ephemeral_5m>0 -> 300s。
# 未过期 -> "Cache HH:MM"（默认色）；已过期 -> "Cache expired"（亮灰）；数据缺失 -> 隐藏。
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
debug_cache_ttl=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    cache_rows=$(tail -n 50 "$transcript_path" 2>/dev/null | \
        jq -c 'select(.type=="assistant" and .message.usage != null)
               | {ts: .timestamp,
                  t5m: (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0),
                  t1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)}' 2>/dev/null)
    if [ -n "$cache_rows" ]; then
        cache_last_ts=$(printf '%s' "$cache_rows" | jq -rs 'last | .ts // empty' 2>/dev/null)
        cache_ttl=$(printf '%s' "$cache_rows" | jq -rs \
            '[.[] | select(.t1h > 0 or .t5m > 0)] | last
             | (if . == null then empty elif .t1h > 0 then 3600 else 300 end)' 2>/dev/null)
        if [ -n "$cache_last_ts" ] && [[ "$cache_ttl" =~ ^[0-9]+$ ]]; then
            cache_last_epoch=$(to_epoch "$cache_last_ts")
            if [[ "$cache_last_epoch" =~ ^[0-9]+$ ]]; then
                debug_cache_ttl="$cache_ttl"
                cache_expires=$(( cache_last_epoch + cache_ttl ))
                cache_now=$(date +%s)
                if [ "$cache_expires" -gt "$cache_now" ]; then
                    cache_hhmm=$(date -d "@${cache_expires}" +%H:%M 2>/dev/null)
                    if [ -n "$cache_hhmm" ]; then
                        line3_segments+=("${E_CACHE} Cache ${cache_hhmm}")
                        rendered_names+=("cache")
                    fi
                else
                    line3_segments+=("${C_SEP}${E_CACHE} Cache expired${C_RESET}")
                    rendered_names+=("cache")
                fi
            fi
        fi
    fi
fi

# ================= 9. 花费区域（第3行）：默认前景色 =================
# 数据源：stdin 的 cost.total_cost_usd（会话累计美元）
cost_usd=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
if [ -n "$cost_usd" ]; then
    cost_str=$(cost_fmt "$cost_usd")
    if [ -n "$cost_str" ]; then
        line3_segments+=("${E_COST} $cost_str")
        rendered_names+=("cost")
    fi
fi

# ================= 组装输出：三行，行内用亮灰色 " | " 分隔 =================
# 第1行：路径 | Git分支
# 第2行：模型 | Token用量 | 5h配额 | 周配额
# 第3行：会话时长 | 内存 | 缓存过期时刻 | 花费
# 某一行全部区域缺失时该行不输出（不留空行）
line1=""
for i in "${!line1_segments[@]}"; do
    if [ "$i" -eq 0 ]; then
        line1="${line1_segments[$i]}"
    else
        line1="${line1}${C_SEP} | ${C_RESET}${line1_segments[$i]}"
    fi
done

line2=""
for i in "${!line2_segments[@]}"; do
    if [ "$i" -eq 0 ]; then
        line2="${line2_segments[$i]}"
    else
        line2="${line2}${C_SEP} | ${C_RESET}${line2_segments[$i]}"
    fi
done

line3=""
for i in "${!line3_segments[@]}"; do
    if [ "$i" -eq 0 ]; then
        line3="${line3_segments[$i]}"
    else
        line3="${line3}${C_SEP} | ${C_RESET}${line3_segments[$i]}"
    fi
done

[ -n "$line1" ] && printf '%b\n' "$line1"
[ -n "$line2" ] && printf '%b\n' "$line2"
[ -n "$line3" ] && printf '%b\n' "$line3"

# ================= 调试文件：每次覆盖写入，绝不包含凭据/token =================
debug_file="$HOME/.claude/statusline/debug.json"
if [ "${#rendered_names[@]}" -gt 0 ]; then
    names_json=$(printf '%s\n' "${rendered_names[@]}" | jq -R . 2>/dev/null | jq -sc . 2>/dev/null)
fi
[ -n "$names_json" ] || names_json="[]"

(
    jq -n \
        --argjson ts "$(date +%s)" \
        --arg quota_source "$quota_source" \
        --arg ctx_tokens "$ctx_tokens" \
        --arg has_cost "$has_cost" \
        --arg cache_ttl "$debug_cache_ttl" \
        --argjson rendered_segments "$names_json" \
        '{
            ts: $ts,
            quota_source: $quota_source,
            ctx_tokens: (if $ctx_tokens == "" then null else ($ctx_tokens|tonumber) end),
            has_cost: ($has_cost == "true"),
            cache_ttl: (if $cache_ttl == "" then null else ($cache_ttl|tonumber) end),
            rendered_segments: $rendered_segments
        }' > "$debug_file"
) 2>/dev/null
