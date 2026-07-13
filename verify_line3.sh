#!/usr/bin/env bash
# 第三行（会话时长 | 内存 | 缓存过期时刻 | 花费）端到端验证
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 脚本自身所在目录 = 仓库根，clone 到任意位置都自适应
S="$DIR/statusline-command.sh"
SCRATCH=$(mktemp -d)
strip() { sed $'s/\x1b\\[[0-9;]*m//g'; }

echo "=========== bash -n 语法检查 ==========="
if bash -n "$S"; then echo "OK: 语法通过"; else echo "FAIL: 语法错误"; exit 1; fi

now=$(date +%s)
reset=$(( now + 13500 ))   # 配额 3h45m

# 生成一行 transcript assistant 记录：epoch t1h t5m
mk_row() {
    local iso; iso=$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z)
    jq -nc --arg ts "$iso" --argjson t1h "$2" --argjson t5m "$3" \
        '{type:"assistant", timestamp:$ts, message:{usage:{cache_creation:{ephemeral_1h_input_tokens:$t1h, ephemeral_5m_input_tokens:$t5m}}}}'
}
# 生成 stdin：dir dur_ms cost_usd transcript_path（transcript_path 传 "" 表示不带该字段）
mk_stdin() {
    jq -nc --arg dir "$1" --argjson dur "$2" --argjson cost "$3" --arg tp "$4" --argjson reset "$reset" \
        '{workspace:{current_dir:$dir},
          model:{display_name:"Opus 4.8 (1M context)"},
          effort:{level:"max"},
          context_window:{total_input_tokens:60009, context_window_size:1000000, used_percentage:6.0},
          rate_limits:{five_hour:{used_percentage:25, resets_at:$reset}},
          cost:{total_duration_ms:$dur, total_cost_usd:$cost}}
         | (if $tp != "" then .transcript_path=$tp else . end)'
}
run() {  # title stdin
    echo; echo "=========== $1 ==========="
    local out; out=$( cd "$SCRATCH" && printf '%s' "$2" | bash "$S" )
    printf '%s\n' "$out" | strip
    printf '%s\n' "--- 行数=$(printf '%s' "$out" | grep -c '^') ---"
}

# 临时 transcript
T1H="$SCRATCH/tr_1h.jsonl"; T5M="$SCRATCH/tr_5m.jsonl"; TEXP="$SCRATCH/tr_exp.jsonl"
mk_row $(( now - 300 )) 1000 0 > "$T1H"          # 1h 写入，300s 前
mk_row $(( now - 300 )) 0 1000 > "$T5M"          # 5m 写入，300s 前
mk_row $(( now - 4000 )) 1000 0 > "$TEXP"        # 1h 写入但 4000s 前 -> 已过期

# 期望的过期时刻（用于自动核对）
exp_1h=$(date -d "@$(( now - 300 + 3600 ))" +%H:%M)   # last+1h
exp_5m=$(date -d "@$(( now - 300 + 300 ))" +%H:%M)    # last+5m
echo; echo ">>> 期望：1h 档过期时刻=$exp_1h ; 5m 档过期时刻=$exp_5m ; TEXP 应为 expired"

run "T1 完整三行（1h TTL，未过期，1h23m，\$1.234）" \
    "$(mk_stdin "$HOME/ws/mine" 4980000 1.234 "$T1H")"
echo ">>> 核对：第3行 Cache 应 = $exp_1h"

run "T2 5m TTL（同起算点，过期时刻应比 1h 早 55 分钟 = $exp_5m）" \
    "$(mk_stdin "$HOME/ws/mine" 4980000 1.234 "$T5M")"
echo ">>> 核对：第3行 Cache 应 = $exp_5m"

run "T3 缓存已过期（4000s 前 + 1h TTL）-> Cache expired" \
    "$(mk_stdin "$HOME/ws/mine" 4980000 1.234 "$TEXP")"

echo; echo "=========== cost 四档小数 ==========="
for c in 1.234 0.1234 0.00423 0; do
    out=$( cd "$SCRATCH" && printf '%s' "$(mk_stdin "$HOME/ws/mine" 60000 "$c" "$T1H")" | bash "$S" | strip | tail -1 )
    echo "cost=$c -> ${out##*| }"
done

echo; echo "=========== 时长三档 ==========="
for d in 30000 2700000 4980000; do   # 30s / 45m / 83m
    out=$( cd "$SCRATCH" && printf '%s' "$(mk_stdin "$HOME/ws/mine" "$d" 0.5 "$T1H")" | bash "$S" | strip | tail -1 )
    echo "dur_ms=$d -> $(printf '%s' "$out" | grep -oE '^Up [^|]*')"
done

echo; echo "=========== 降级：无 cost 对象（Up 与 \$ 应隐藏，第3行仅 RAM+Cache）==========="
NOCOST=$(jq -nc --arg dir "$HOME/ws/mine" --arg tp "$T1H" --argjson reset "$reset" \
    '{workspace:{current_dir:$dir}, model:{display_name:"Sonnet 4.6"},
      context_window:{total_input_tokens:120000, context_window_size:200000, used_percentage:60},
      rate_limits:{five_hour:{used_percentage:55, resets_at:$reset}},
      transcript_path:$tp}')
run "T4 无 cost 对象" "$NOCOST"

echo; echo "=========== 降级：无 transcript（Cache 应隐藏）==========="
run "T5 无 transcript_path" "$(mk_stdin "$HOME/ws/mine" 60000 0.5 "")"

echo; echo "=========== 原始带色抽查（T1，确认第3行为默认色、Cache expired 才灰）==========="
( cd "$SCRATCH" && printf '%s' "$(mk_stdin "$HOME/ws/mine" 4980000 1.234 "$TEXP")" | bash "$S" ) | cat -v | tail -1

echo; echo "=========== 调试文件 has_cost / cache_ttl 字段 ==========="
( cd "$SCRATCH" && printf '%s' "$(mk_stdin "$HOME/ws/mine" 60000 0.5 "$T1H")" | bash "$S" >/dev/null )
echo "1h stdin -> $(jq -c '{has_cost, cache_ttl, rendered_segments}' "$DIR/debug.json" 2>/dev/null)"
( cd "$SCRATCH" && printf '%s' "$(mk_stdin "$HOME/ws/mine" 60000 0.5 "$T5M")" | bash "$S" >/dev/null )
echo "5m stdin -> $(jq -c '{has_cost, cache_ttl}' "$DIR/debug.json" 2>/dev/null)"
( cd "$SCRATCH" && printf '%s' "$NOCOST" | bash "$S" >/dev/null )
echo "无cost  -> $(jq -c '{has_cost, cache_ttl}' "$DIR/debug.json" 2>/dev/null)"

echo; echo "=========== 前两行回归（home 无 git，确认未被破坏）==========="
run "T6 home + 前两行" "$(jq -nc --argjson reset "$reset" \
    '{workspace:{current_dir:"'"$HOME"'"}, model:{display_name:"Fable 5"}, effort:{level:"high"},
      context_window:{total_input_tokens:170000, context_window_size:200000, used_percentage:85},
      rate_limits:{five_hour:{used_percentage:90, resets_at:$reset}}}')"

echo; echo "=========== 性能：单次刷新耗时 ==========="
TIMEFORMAT='%3R 秒'
time ( cd "$SCRATCH" && printf '%s' "$(mk_stdin "$HOME/ws/mine" 4980000 1.234 "$T1H")" | bash "$S" >/dev/null )

rm -f "$T1H" "$T5M" "$TEXP"
