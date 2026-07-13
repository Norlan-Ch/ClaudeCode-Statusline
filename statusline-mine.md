---
description: 把 Claude Code 的 statusLine 与 subagentStatusLine 一并切回我的自定义脚本（主三行布局 + subagent 面板行），热重载、无需重启即时生效
allowed-tools: Bash(jq:*), Bash(mv:*)
---

请**原封不动**执行下面这段 Bash，把 `/home/dralfo/.claude/settings.json` 的 `.statusLine.command`（主三行）与 `.subagentStatusLine.command`（subagent 面板行）一并切回我的自定义脚本。只改这两个字段（各自 `type` 缺失时才顺带补回 `command`），保留其余所有设置；先用 `jq` 写临时文件、成功后再 `mv` 原子覆盖。执行后把最后那行提示原样转达给我，不要多做别的。

```bash
SETTINGS="/home/dralfo/.claude/settings.json"
MINE="bash /home/dralfo/.claude/statusline/statusline-command.sh"
SUB="bash /home/dralfo/.claude/statusline/subagent-statusline.sh"
jq --arg cmd "$MINE" --arg sub "$SUB" '
    .statusLine.type //= "command" | .statusLine.command = $cmd
  | .subagentStatusLine.type //= "command" | .subagentStatusLine.command = $sub
' "$SETTINGS" > "$SETTINGS.tmp" \
  && mv "$SETTINGS.tmp" "$SETTINGS" \
  && echo "已切回自定义 statusline（主行 + subagent 面板行），无需重启、下一次刷新事件即生效（发条消息就能触发）；若没更新可重启 Claude Code 兜底。"
```
