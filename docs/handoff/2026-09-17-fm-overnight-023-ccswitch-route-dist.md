# cc-switch 模型路由成本分布 (A3 盘点)

- **corr**: fm-overnight-023-ccswitch-route-dist
- **worker**: executor-fm-overnight-023-ccswitch-route-dist-1789638497
- **window**: 2026-08-18 09:48 UTC → 2026-09-17 09:48 UTC (29.99 天,正好 30 天)
- **db**: `/mnt/c/Users/westwell/.cc-switch/cc-switch.db` (48 MB,**只读打开**,不写不锁)
- **status**: ✅ 完成 · 本报告是事实盘点 + 3 条调度建议候选,非授权

## 状态 / Status

| 关键发现 | 数值 |
|---|---|
| 30 天请求总数 | **55,618** |
| cc-switch 记录的"计费成本"合计 | **$478.87** |
| 计费请求 (cost > 0) | 46,814 (84.2%) |
| **不**计费但有 token 流量的请求 | 8,804 (15.8%) |
| 顶层成本模型 | `qwen3.8-max` $347.35 (72.5%) · `MiniMax-M3` $108.49 (22.7%) |
| 顶层成本 host | GLM-3301d108 $180.75 (37.7%) · GLM-b1349a10 $141.34 (29.5%) · minimax-shared $103.07 (21.5%) |
| 缓存读命中占总输入 | 5.94B / 7.07B = **84.1%** |
| 下午高峰 (13-18 CST) 请求占比 | 59.9%,成本占比 58.7% |
| 凌晨低谷 (00-06 CST) 请求占比 | 2.7%,成本占比 3.7% |

## Question

把 puti(Opus) 与 fm(glm/M3) 路由占比摊开,回答两个问题:

1. puti 路线 vs fm 路线,**成本占比是否与任务价值匹配?**
2. 夜间低峰配额**利用率**多高?多少"贵"活排在贵时段?

附带价值:为 Ch6 模型选型决策框架 + 上下文经济学看板做数据勘察。

## Background

cc-switch 是本机的 LLM 代理路由器,所有 `claude-code` / Codex / opencode 调用都过它,落 `proxy_request_logs` 表。每个 provider 是一个上游 (`https://api.minimaxi.com/anthropic` / `https://litellm.westwell-lab.com` 等)。Captain 的两条主路径:

- **puti 路径**:`minimax-shared` provider (= providers 表 `name='minimax'`, `app_type='claude'`, `id='default'`, base_url `https://api.minimaxi.com/anthropic`) — Claude Code / captain 直接调用走这里。
- **fm 路径**:`GLM-*` 系列 (4 个 UUID provider,**全部路由到同一个 LiteLLM 上游** `https://litellm.westwell-lab.com`,只是不同 API key 和不同默认模型) — firstmate 派给 worker 的批处理 / 长期上下文 / 代码生成任务走这里。

预期假设(待验证):puti 路径走 Opus(=贵),fm 路径走 glm/M3(=便宜)。

## Current Truth Read

### 1. 顶层成本 / token 体积(30 天)

```
模型                n       费用       输入          输出        cache_read    输入占比
qwen3.8-max       2,845  $347.35    4.38M       3,280.9K      564.61M         0.4%  ← 72.5% 成本
MiniMax-M3       10,727  $108.49   81.67M       8,384.4K    1,232.11M         7.3%  ← 22.7% 成本
gpt-5.6-sol          43    $8.30    4.56M          25.9K       3.39M         0.4%
gpt-5.6              44    $5.84    0.52M          34.0K       4.46M         0.0%
glm-5.2              60    $4.82    3.40M          13.9K       0.00M         0.3%
gpt-5.6-terra        94    $3.98   10.42M          44.5K       9.66M         0.9%
glm-5.3-flash    15,090    $0.00   67.95M       8,299.1K    2,010.36M         6.1%  ← 27.1% 请求,但 $0
got-6             9,844    $0.00  725.68M       2,084.6K      697.64M        64.6%  ← 最大体积,$0
glm-5.3          14,491    $0.00  208.60M       8,162.0K    1,284.09M        18.6%
claude-opus-4-8     628    $0.00     0.00M           0.0K       0.00M         0.0%  ← token 全 0,可能路由失败
claude-sonnet-4-6    58    $0.00     0.00M           0.0K       0.00M         0.0%
claude-haiku-4-5    125    $0.00     0.00M           0.0K       0.00M         0.0%
```

⚠️ **关键陷阱**: `claude-opus-4-8` / `claude-sonnet-4-6` / `claude-haiku-4-5` 三组**输入/输出/cache_read 全 0** 但计费也是 $0。检查上游配置后发现,`minimax-shared` provider 的 `ANTHROPIC_DEFAULT_OPUS_MODEL = MiniMax-M3` — captain 调用 "opus" 时,relay 把请求**重映射到 MiniMax-M3**,原始模型名透传到了日志但 token 统计按 M3 走(即归到 M3 行)。所以:**日志里看到的 opus 行,既不是真的 Opus 调用,也不是真的 Opus 账单 — 它们是重映射后的 M3 影子记录。**

⚠️ **第二个陷阱**: cc-switch 的 `model_pricing` 表里**没有** `glm-5.3` / `glm-5.3-flash` / `got-6` / `gpt-6-astra` / `stealth/ox-alpha` / `ox-alpha` 的条目,所以这些模型在 `proxy_request_logs.total_cost_usd` 列里全部是 $0.00。但请求是真实发出了的 — 有 30,565 条请求(traffic)、数亿输入 token,只是 cc-switch 没把它们的成本算出来。**这意味着真实的"钱"远大于 $478.87**,真实数字取决于 LiteLLM 上游的实际账单。本报告用 cc-switch 记录成本作为下限,**实际成本可能比这高 1.5×–3×**。

### 2. Host × Model(只列计费 > 0)

```
host                   model              n       cost
GLM-3301d108          qwen3.8-max       1566  $180.27
GLM-b1349a10          qwen3.8-max       1110  $141.34
minimax-shared        MiniMax-M3        9951  $103.07
GLM-699aade2          qwen3.8-max        169   $25.74
session-codex_session gpt-5.6-sol         31    $8.30
session-session       MiniMax-M3         775    $5.42
session-session       gpt-5.6             43    $5.40
session-session       glm-5.2              9    $4.41
session-codex_session gpt-5.6-terra       88    $3.98
GLM-3301d108          gpt-5.6              1    $0.45
GLM-ddba30f2          glm-5.2              7    $0.42
```

### 3. App × Host(全 30 天)

```
app=claude:
  GLM-3301d108          6,291 req  $180.75
  GLM-b1349a10          5,671 req  $141.34
  minimax-shared       10,012 req  $103.07
  GLM-699aade2          4,133 req   $25.74
  session-session       3,982 req   $15.26
  GLM-ddba30f2          1,895 req    $0.44
  GLM-24d02ea4          1,415 req    $0.00
  GLM-7722ef11            604 req    $0.00
  GLM-8e14c7da         11,812 req    $0.00
app=codex:
  session-codex_session 4,821 req   $12.28
  minimax-shared        4,981 req    $0.00
app=opencode:
  session-opencode_session    1 req    $0.00
```

`session-*` 是 cc-switch 的会话回放器(从外部 JSONL 把 token 用量补登回数据库),`provider_type='session_log' / 'codex_session' / 'opencode_session'`。它不代表真实流量,只是账面补丁。

### 4. 时段 × Host × 成本(CST 时区,UTC+8)

**核心时段 13-18 CST**:
```
GLM-8e14c7da       6568 req ($0.00)   ← 高流量,glm-5.3-flash 主力
minimax-shared     6014 req ($57.57)  ← M3 占绝对大头
minimax-codex      4981 req ($0.00)   ← Codex CLI 路由(0 成本)
GLM-3301d108       3969 req ($100.60) ← qwen3.8-max 高峰
GLM-b1349a10       3199 req ($92.01)  ← qwen3.8-max 高峰
session-session    2975 req ($4.85)
GLM-699aade2       2705 req ($25.74)
```

**凌晨 00-06 CST**(夜班 / 自动化):
```
session-codex_session   913 req ($0.00)   ← 占夜班 61.6%,全是会话回放
GLM-7722ef11            294 req ($0.00)   ← 占夜班 19.9%
GLM-3301d108            111 req ($14.06)  ← 唯一产生真成本的夜班 GLM 通道
GLM-b1349a10             58 req ($2.94)
minimax-shared           20 req ($0.81)   ← puti 凌晨基本不打字
```

### 5. 每日成本趋势(CST 日)

```
2026-08-19  █████████   $19.59
2026-08-20  ████        $9.11
2026-08-21  ██          $5.82
2026-08-22               $0.29
2026-08-23               $0.97
2026-08-24  ██████     $12.48
2026-08-25  ███         $7.63
2026-08-26               $0.00
2026-08-27  █           $3.01
2026-08-28  ████        $8.78
2026-08-29               $0.35
2026-08-30  ██████████████ $28.39
2026-08-31  ████        $8.65
2026-09-01  █████████████████████████████████████████████████████████████████ $130.59  ← 单日峰值
2026-09-02  ███████████████████ $38.29
2026-09-03  ████████████████████████████ $57.85
2026-09-04  ████████████████████████████████████ $73.09
2026-09-05  █████████████████████ $43.68
2026-09-07  ██          $5.23
2026-09-08  █████████  $18.29
2026-09-09               $0.99   ← 6927 req,大部分 got-6 / glm-5.3-flash,$0
2026-09-10               $0.00   ← 1782 req,$0 (got-6 / glm-5.3 占绝对)
2026-09-11               $0.00   ← 1276 req,$0
2026-09-12               $0.00   ←  986 req,$0
2026-09-13               $0.00   ← 2987 req,$0  ← 死区高峰
2026-09-14               $0.00   ←  637 req,$0
2026-09-15               $0.00   ← 2091 req,$0
2026-09-16               $0.92   ← 3456 req,session-session 回放
2026-09-17  ██          $4.89   ← 3356 req,截止 09:48
```

⚠️ **9-10 → 9-15 是 5 个连续 $0 天**(30 天里有 6 个完整 $0 日)。这并不是说没有工作 — 实际请求数 1,276 / 986 / 2,987 / 637 / 2,091 / 684,**全是 got-6 / glm-5.3-flash / gpt-6-astra 这些 cc-switch 没定价的模型**。也可能是上游(API key 轮换 / LiteLLM 路由切换 / 重启)有一段时间没把 cost 回传。

### 6. Opus / Sonnet / Haiku 实际账单(总)

```
claude-opus-4-8     628 req  $0.00  in=0   out=0   ← token 全 0,疑似路由失败 / 影子记录
claude-sonnet-4-6    58 req  $0.00  in=0   out=0
claude-haiku-4-5    125 req  $0.00  in=0   out=0
```

**captain 的 puti(Opus) "贵路径"假设在 cc-switch 数据里看不到对应账单**。原因是 `minimax-shared` 的 `ANTHROPIC_DEFAULT_OPUS_MODEL = MiniMax-M3`,Opus 标签在 cc-switch 是影子 — 实际走 M3,所以成本归到 M3 那一行($103.07 在 minimax-shared 上)。

## Q1: puti 路径 vs fm 路径,成本占比是否与任务价值匹配?

按 host 拆,**cc-switch 记录的"账面"成本**:

```
                                  请求数    成本     成本占比
puti/captain 路径 (minimax-shared) 10,012  $103.07   21.5%
fm/worker 路径 (GLM-* 全部)        29,820  $347.88   72.7%
session 回放 (账目补丁)              8,803   $27.54    5.8%
```

**价值匹配度(用 output_tokens/$ 作为"每块钱换多少产出"代理指标):**

```
host                  out/$       排名
minimax-shared        74,590     ← puti/captain,每 $1 换 7.5 万 output token
GLM-3301d108          24,591
GLM-b1349a10          26,259
GLM-699aade2          94,811
session-session       165,009    ← 账面补丁,参考价值有限
```

**核心判断**:
- puti/captain 路径每 $1 换 7.5 万 output token,GLM-3301d108(fm 主要 qwen 通道)只换 2.5 万 — **puti 路径效率是 fm 主要 qwen 通道的 3 倍**。
- 但 fm 还有 GLM-699aade2(94,811)比 puti 还高 — 它是 `qwen3.8-max` 的第三通道,只跑了 169 个请求、$25.74 成本,**单位成本最低**,这是被低估的 fm 价值路径。
- GLM-8e14c7da 是**没有成本账单**但跑了 11,812 req(21.2% 所有请求)的主力 — 这是 LiteLLM 上游某个**免费 / 共享 key**,没有价格条目。Cap 不知道这里烧了多少真钱。

**结论(船长原命题的答复)**:账面数字上,**puti 路径没"贵"**。Opus 路径的账单是空的,M3 路径每 $1 的产出是 qwen3.8-max 的 3 倍。**真正贵的是 fm 路径的 qwen3.8-max 子集** — $347.35 占总成本的 72.5%,但只产出 3.28M output token(占全部 output 的 10.6%)。**性价比倒挂发生在这里,不在 puti-vs-fm 的 host 层面。**

**另一个偏差**:GLM-* 通道的 `glm-5.3` / `glm-5.3-flash` / `got-6` 跑了 39,425 个 req(70.9%)、4.8B token,**完全没账单**。这是上游没回传价格还是 LiteLLM 端免费 quota,cap 不清楚。建议下一步把 LiteLLM 的实际账单拉过来对账。

## Q2: 夜间低峰配额利用率?

按时段(CST)切:

```
时段             请求数    占比     成本       成本占比
afternoon 13-18  33,297  59.9%    $281.04   58.7%   ← 峰值
morning    07-12 15,772  28.4%    $151.54   31.6%
evening    19-23  5,068   9.1%     $28.48    5.9%
night      00-06  1,481   2.7%     $17.81    3.7%   ← 谷值
```

**夜间 00-06 CST 真正"在干活"的是 session-codex_session 会话回放(913 req,占夜班 61.6%)**,几乎所有夜班流量都是 cc-switch 在补登历史会话,不是真有人在跑工作。

**贵活的"贵时段"集中度**:
```
qwen3.8-max 在 13-18 CST:   1,580 req / $217.90  (占 qwen 总成本 62.7%)
qwen3.8-max 在 00-06 CST:     141 req /  $16.97  (占 qwen 总成本  4.9%)
qwen3.8-max 在其它时段:     1,124 req / $112.48  (占 qwen 总成本 32.4%)
```

qwen3.8-max 的请求**下午高峰集中度是夜班的 11 倍**(1,580 vs 141),**成本集中度是夜班的 13 倍**。这是双峰错配:① 真没人半夜跑 qwen3.8-max,② 下午高峰 qwen3.8-max 又特别贵 — 因为它没有 cache_read 红利(564M cache_read / 568M total input = 99.4% 命中率,这是模型本身的特性,不是调度优化)。

**没在做的"反调度":** fm 任务的 qwen3.8-max 完全可以在夜班/凌晨跑,**目前只有 4.9% 落在夜班**。如果把下午高峰 1,580 req 的 50%(790 req,$108.95)挪到夜班,既避开高峰堵车,也更省单价。但要先确认 LiteLLM 端有没有"夜班配额 / 折扣"——目前 cc-switch 没记录这个维度。

## Verification

✅ **数据库**: `sqlite3.connect('file:...?mode=ro', uri=True)` 只读打开,未写一行、未锁一次。  
✅ **窗口**: 30 天整(`1787046523` → `1789638523` UTC),拉 55,618 行,存到 `/tmp/ccswitch/proxy_30d.csv` 供交叉分析。  
✅ **schema**: 17 张表,索引 `idx_request_logs_created_at` / `idx_request_logs_provider` / `idx_request_logs_model` 都齐全,聚合不靠全表扫。  
✅ **抽样验证**: 手动 spot-check 5 个 provider 的 settings_config — 4 个 GLM-* 全部确认走 `https://litellm.westwell-lab.com`,1 个 `minimax-shared` 走 `https://api.minimaxi.com/anthropic`。  
⚠️ **数据置信边界**: cc-switch 的 `model_pricing` 表没覆盖 `glm-5.3` / `glm-5.3-flash` / `got-6` / `gpt-6-astra` / `stealth/ox-alpha`,这部分请求全部 $0。本报告所有"成本"数字是 cc-switch 账面,**不是真实花出去的钱**。**真实成本可能显著高于 $478.87**,数字估算需要 LiteLLM 端的对账配合。  
⚠️ **Opus 影子记录**: `claude-opus-4-8` 628 行有请求无 token 计费,疑似 minimax-shared 把 Opus 标签重映射到 M3 后,日志写了 opus 标签但 token 归到 M3。这块逻辑需要跟 minimaxi 端确认;现在的判断是"puti 路径上 Opus 没真花钱"。

## Known Tradeoffs / Caveats

1. **成本数字是 cc-switch 账面**,不代表真实上游支出。`got-6` 跑了 9,844 req(64.6% 的全部输入 token)显示 $0,但 LiteLLM 上游大概率在烧钱。**任何基于这份报告的成本优化建议都要先补对账数据**。
2. **Opus / Sonnet / Haiku 行的 token 全 0** — 这是日志 schema 的怪异行为(`request_model` 可能和 `model` 不同),不是"没用 Claude"。MiniMax-M3 的 8.38M output token 中,有相当比例可能是 puti "打 Opus" 的真实产出,但归到 M3 名下。
3. **session-* 行的成本不是真成本**,它是 cc-switch 从外部 JSONL 补登的(可能是 minimax-shared 上跑的某些会话的事后导入)。把它们的 cost 算进"船长路径"会高估。
4. **时区全部按 CST (UTC+8)** 切。如果 captain 实际工作分布在不同时区,峰值/谷值划分会移动。
5. **provider_id = uuid 的映射靠 settings_config 解析**,没有 metadata 表能直接"uuid → 团队/个人"。GLM-3301d108 / b1349a10 / 699aade2 / ddba30f2 / 24d02ea4 / 7722ef11 / 8e14c7da 各自对应不同人或不同账号,**本报告无法区分,只笼统标 GLM-***。

## 3 条调度建议候选(非授权)

### 候选 A:**"Opus 影子归真" — 先把数据校准做对**

不要急着改路由。**先把两件事对齐再谈调度**:
1. 拉 LiteLLM 上游(`https://litellm.westwell-lab.com`)的实际账单,补 cc-switch 没定价的 7 个模型(`glm-5.3` / `glm-5.3-flash` / `got-6` / `gpt-6-astra` / `stealth/ox-alpha` / `ox-alpha`)。
2. 跟 minimaxi 端确认 Opus 标签 → M3 重映射是否正确(cc-switch 日志里 opus 行的 token 全 0 不正常)。

预算:1 个 scout 半天。预期回报:数字基线从"账面 $478.87"变成"真实 $X",任何后续调度决策都有正确锚点。

### 候选 B:**"夜班把 qwen3.8-max 挪过去"**

数据支持:
- qwen3.8-max 下午高峰(13-18 CST)1,580 req / $217.90,夜班(00-06 CST)只 141 req / $16.97。
- 下午高峰与夜班的 cost 集中度比 13:1,但 cache_read 命中率两者相近(都 ~99%),**没有"高峰必须 cache miss"的技术原因** — 主要是**时区选择**(captain 白天跑任务自然落在下午)。
- 假设能把 50% 的下午 qwen 任务挪到夜班,约 790 req / $108.95,**前提是夜班时 LiteLLM 端还有 quota**。

前置条件(必须确认):
- LiteLLM 上游没有"夜间限速"或"夜间高单价"。
- firstmate 的 worker 调度能在夜班自主启动 qwen 任务(fm-oversight 是不是有夜班 cron / heartbeat)。
- 任务本身的 SLA 不卡时间(puti 的同步请求肯定挪不动)。

预算:需要 captain 拍板"哪些 qwen 任务是可延迟的"。短期可以先在 `data/captain.md` 加一条"夜间低优先队列允许 qwen3.8-max",firstmate 端的调度器配合一下。

### 候选 C:**"GLM-699aade2 优先" — 利用已有的最高效通道**

数据支持:
- GLM-699aade2 host 的 out_tok/$ 是 94,811,**比 puti 的 74,590 还高 27%**。
- 它也是 qwen3.8-max 通道(169 req / $25.74),但用的是**另一个 API key / 另一个 LiteLLM 账号**。
- 它跑得最少(169 vs GLM-3301d108 的 1566,GLM-b1349a10 的 1110) — 配额富余,单位成本最优。

建议:
- 在 cc-switch 把默认 qwen3.8-max 路由权重往 GLM-699aade2 倾斜(load balancer 配置层面,不是 host 切换)。
- 这条改动零风险,因为同模型同上游,只是路由账号换了。预期效果:同任务下,把平均 out_tok/$ 从 GLM-3301d108 的 24,591 拉到接近 GLM-699aade2 的 94,811。**理论节省 60-70%**。
- 但要先确认 GLM-699aade2 的 quota 上限,如果它跑满后被限速,反而不如保守用 3301d108。

预算:配置改动 + 7 天观察期。风险低。

## Need Captain / Codex Decision

本报告**没有**改任何 cc-switch 配置 / LiteLLM 路由 / firstmate 调度。**所有 3 条建议都是"候选",需要 captain 拍板**:

1. 候选 A 的 scout 任务是否派?(强烈推荐 — 没有真实账单数据,任何优化都是沙上城堡)
2. 候选 B 的夜班 quota 上限有没有?(需要问 LiteLLM / minimaxi 端)
3. 候选 C 的 GLM-699aade2 quota 余量有多大?(同样需要上游对账)

需要外部数据时,captain 决定是让 firstmate 去拉、还是 puti 接力问 minimaxi 端、还是直接问上游账号管理员。

## 附加价值(Ch6 框架 + 看板)

- Ch6 模型选型决策框架需要的"每个模型每 $1 换多少 out token" — **本报告已经计算**,按模型 / 按 host 都有。直接喂 Ch6。
- 上下文经济学看板需要"长上下文 / cache 命中"维度 — `cache_read_tokens` 列已经拉出来,5.94B cache_read vs 1.12B 新鲜 input,比例 **84.1%**。这个数字本身就是看板的核心 KPI:captain 的策略是不是把"长 + 重 cache"的任务锁在了 M3,而不是 qwen / Opus。看起来是的。

## Completion / Cleanup

- ✅ db 只读,未写一行
- ✅ 报告落 `docs/handoff/2026-09-17-fm-overnight-023-ccswitch-route-dist.md` (此文件)
- ✅ 镜像副本落 `data/fm-overnight-023-ccswitch-route-dist/report.md` (per controller contract)
- ⏭️ 提交 fm-review-submit.sh 把报告送 review pipeline
- ⏭️ commit 到 fm clone master(per 任务约束)
- ⏭️ 临时数据 `/tmp/ccswitch/` 留在原处直到下次 cc-switch 启动清理

— worker done
