---
description: 把 Claude Code 的 statusLine 与 subagentStatusLine 一并切回我的自定义脚本（主三行布局 + subagent 面板行），热重载、无需重启即时生效
allowed-tools: Bash(jq:*), Bash(mv:*)
---

请**原封不动**执行下面这段 Bash：它先顺着 `~/.claude/commands/statusline-mine.md` 这条软链自动反推出本仓库所在目录（clone 到任意位置都自适应、不硬编码），再把 `settings.json` 的 `.statusLine.command`（主三行）与 `.subagentStatusLine.command`（subagent 面板行）一并切回仓库里的自定义脚本。只改这两个字段（各自 `type` 缺失时才顺带补回 `command`），保留其余所有设置；先用 `jq` 写临时文件、成功后再 `mv` 原子覆盖。执行后把最后那行提示原样转达给我，不要多做别的。

```bash
set -euo pipefail
# 配置目录：尊重 CLAUDE_CONFIG_DIR，缺省 ~/.claude
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
# 顺着命令软链反推仓库目录（install.sh 保证该软链指向本仓库真实文件），故 clone 到任意位置都自适应
SELF="$(readlink -f "$CLAUDE_DIR/commands/statusline-mine.md")"
REPO_DIR="$(cd "$(dirname "$SELF")" && pwd)"
MINE="bash $REPO_DIR/statusline-command.sh"
SUB="bash $REPO_DIR/subagent-statusline.sh"
# 兜底：仓库脚本必须存在，否则明确报错，绝不把 settings 写坏
[ -f "$REPO_DIR/statusline-command.sh" ] && [ -f "$REPO_DIR/subagent-statusline.sh" ] \
  || { echo "错误：未在 $REPO_DIR 找到 statusline 脚本；请先在仓库目录跑一次 bash install.sh" >&2; exit 1; }
# settings.json 不存在则以空对象起步（全新配置目录也能一键设置）
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq --arg cmd "$MINE" --arg sub "$SUB" '
    .statusLine.type //= "command" | .statusLine.command = $cmd
  | .subagentStatusLine.type //= "command" | .subagentStatusLine.command = $sub
' "$SETTINGS" > "$SETTINGS.tmp" \
  && mv "$SETTINGS.tmp" "$SETTINGS" \
  && echo "已切回自定义 statusline（主行 + subagent 面板行），无需重启、下一次刷新事件即生效（发条消息就能触发）；若没更新可重启 Claude Code 兜底。"
```
