# 调查：statusline 第三行「时长/花费」与 session 切换的重置行为

> 状态：**已收尾（2026-07-09）**。结论落地为「维持进程级直读」，一度实现的「按 session_id 归零」方案已回退。
> 相关代码：`statusline-command.sh` 第 6 节（时长）、第 9 节（花费）。设计总纲见 `DESIGN.md`。

## 1. 缘起

第三行的「🕐 会话时长」「💰 花费」直读 stdin 的 `cost.total_duration_ms` / `cost.total_cost_usd`。
用户观察到：在会话中 `/clear` 后，这两项**不会归零**，而是在原值上继续累加。
诉求：`/clear` 开新话题后，时长/花费应从零重新计。

## 2. 核查到的事实（官方文档 + 本地实测双重确认）

### 2.1 `cost` 对象是「进程级」，不是「会话级」
- 官方 statusline 文档：`cost.total_cost_usd` = *"Estimated session cost in USD"*，`cost.total_duration_ms` = *"Total wall-clock time since the session started"*——但**未定义 "session" 的边界**。
- 实测结论：这里的 "session" 实为 **`claude` CLI 进程的生命周期**。只要进程不重启，计数就持续累加。

### 2.2 `/clear` 会轮换 `session_id`，但不重启进程
- 官方 sessions 文档：`/clear` = *"start fresh with an empty context. The previous conversation is saved and resumable"* → 开一个**新会话（新 `session_id`、新 transcript 文件）**，旧的留存可 resume。
- 本地 transcript 实测（v2.1.201/202）：每次 `/clear` 新开一个 `<session-id>.jsonl`，`/clear` 命令记录在新文件顶部，`parentUuid` 链回旧会话末尾。
- **但进程没重启** → `cost.*` 继续累加 → 所以 `/clear` 不归零。

### 2.3 `/resume` 复用同一个 `session_id`（关键，纠正过一次误判）
- 官方 sessions 文档铁证：*"If you resume the same session in two terminals without forking, messages from both **interleave into one transcript**."* → resume **复用原 `session_id`、追加同一 transcript 文件**。
- 只有 `--fork-session` / `/branch` / `/rewind` 才造**新 id**（fork）；裸 `--resume` / `--continue` / `/resume` 不 fork。
- 调查中一度用「transcript 内部大时间空隙」误判 resume 造新 id——实为「同进程挂着等用户隔夜回答 `AskUserQuestion`」（tool_use→tool_result 链未断），该信号作废。

### 2.4 `/resume` 虽复用 id，但走**新进程**，`raw` 从 0 起（H2，实测坐实）
- resume 通常是新进程；`cost.*` 是进程级计量，新进程从 ~0 起。
- 用户实测：`/resume` 旧会话后，debug.json 的 `cost_base`（= resume 首帧 raw 值）**从 0 开始** → 证实新进程不恢复旧会话历史花费。
- 推论：被 resume 的旧会话的「历史累计花费」**既不在 `raw` 里、也没存进 transcript**（transcript 只落 per-message token `usage`，不落累计美元）→ **历史值无处可取**。

### 2.5 三种「重置点」对照

| 操作 | `session_id` | transcript | `cost.*` / 时长 |
|---|---|---|---|
| **`/clear`** | 换新 id | 新文件 | **不重置**（同进程继续累加） |
| **`/resume` / `--resume` / `--continue`** | **复用原 id** | 追加原文件 | **重置为 ~0**（新进程，且不恢复历史） |
| **`/compact`** | 不变 | 同文件 | 不重置（继续累加） |
| **`/branch` / `--fork-session` / `/rewind`** | 换新 id（fork） | 新文件 | 新进程 → ~0 |
| **退出 `claude` 重新启动** | 换新 id | 新文件 | **归零**（唯一「干净」的真重置） |

## 3. 试过的方案与为何回退

**方案（2026-07-08 曾上线）**：以 `session_id` 为 key，在 `~/.claude/statusline/state/<sid>.json` 存「首见时的基线」`{cost_base, dur_base_ms}`，第三行显示 `raw − 基线`。因 `/clear` 换 `session_id`，每次 `/clear` 自动重取基线 → 时长/花费从零起。该方案对 `/clear` 有效，经对抗性测试（写盘失败回退、负增量 clamp、路径逃逸校验）通过。

**回退原因（2026-07-09）**：
1. **救不了 `/resume`**：resume 复用同一 `session_id` 但走新进程、`raw` 从 0 起（见 2.4）。基线机制下，resume 要么被当「首见」重新归零、要么读到旧基线后因 `raw < 基线` 被 clamp **卡死在 0**——两种都不是用户要的「从历史值续上」，而历史值根本取不到。
2. **复杂度不划算**：为一个只覆盖 `/clear`、且会把 `/resume` 弄得更怪的效果，引入了 `state/` 目录、per-session 基线文件、`find -mtime` 清理 + `touch` 保活、原子写、负增量兜底等一整套机制。收益与复杂度不成比例。

**最终决定**：**回退到进程级直读**——第三行「时长/花费」就是「当前 `claude` 进程自启动以来」的累计值。语义简单、无额外状态、无清理负担。想真正归零就退出重开 `claude`（新进程）。

## 4. 结论

- 「`/clear` 后时长/花费归零」**在 statusline 数据层面无法干净实现**——`cost.*` 是进程级的，Claude Code 未提供会话级/对话级口径，历史值也未持久化。
- 现状即最简自洽方案：第三行反映**进程级**累计；`/clear`、`/resume`、`/compact` 都不影响它，只有退出重启进程才归零。
- 若 Claude Code 未来在 stdin 暴露「会话级 cost」或「resume 时恢复历史 cost」，可重新评估。
