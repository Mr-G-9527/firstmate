# External Redteam (opencode + MiniMax-M3) · fm 侧使用说明

> 2026-08-22 由 puti 部署。协议唯一权威 = `~/.claude/skills/red-team/SKILL.md`
> (symlink -> /mnt/c/Users/westwell/.claude/skills/red-team/SKILL.md, Windows 侧 canonical,
> 勿在本仓复制正文, 防双权威漂移)。

## 何时用

- 关键节点对抗审计: spec 拍板前 / phase 产出交接前 / 硬规则或协议改动前 / captain 说 "red team"
- 与 internal fresh-context 侧并行跑同一份 brief, reconcile 后写进 review

## 怎么调 (一条命令)

```bash
python3 ~/.claude/skills/red-team/scripts/redteam-ext-opencode.py <brief.md>
```

- brief 必须包含: North Star / Decision under review / 关键事实 / 约束
  (对称输入: internal 侧拿同一份, 双方都不读 main self-report)
- 产物: `<brief>-ext-response.json` (模型输出) + `<brief>-ext-run.json` (canonical run record)
- run record 是报告唯一 evidence reference: 报告里必须 cite 它, 且
  `run=completed` 才允许出现 D-# finding; `failed` -> "External findings: unavailable"

## 证据契约 (v3.1, 与 Windows 侧 redteam-ext-glm.py 同构)

- `run_status`: completed 仅当 finish_reason==stop 且 content/reasoning 至少一个非空
- `identity_verified`: 独立事实, 不盖 run 成败 (verified=false 只降异构性主张)
- 失败也原子落盘 run record (exit 非零 + 原始错误), 不静默

## 已知事实 (2026-08-22 e2e 实测)

- opencode 1.18.21 二进制: `~/.npm-global/bin/opencode` (npm 官方源在 WSL 卡死,
  走 npmmirror tarball 手动放置; 升级同样方式)
- provider 配置: `~/.config/opencode/opencode.json` (openai-compatible,
  baseURL=api.minimaxi.com/v1, model id 必须是 `MiniMax-M3`, key 复用 fm 侧
  Claude settings 同一 token; 文件 600)
- 专用 agent `redteam`: disable=true (禁所有 tool) + edit/bash deny —— 必须
  `--agent redteam` 调用; 用默认 build agent 时 M3 会试图读项目文件,
  finish_reason=tool-calls, 证据契约正确判 failed
- M3 经 opencode 把思考放 `<think>...</think>` 前缀, 脚本已拆进 reasoning 字段
- 实测一次完整 redteam call ~58s, reasoning ~14K chars (M3 量大管饱, 放心跑)

## 与 Windows 侧的分工

| | Windows (puti) | WSL (fm) |
|---|---|---|
| 外部侧 harness | dsh/litellm -> glm-5.3 | opencode -> MiniMax-M3 |
| 脚本 | `~/.claude/skills/red-team/scripts/redteam-ext-glm.py` | `~/.claude/skills/red-team/scripts/redteam-ext-opencode.py` |
| 异构主张 | 模型异构 (glm vs claude) | harness 异构 (opencode vs Claude Code), owner 2026-08-19 拍板 |

## 维护人

puti (菩提) 部署 · fm (firstmate) 使用 · 2026-08-22
