# 提交与推送规则

> 本文件是仓库的「边界 + 流程」约定。改 RTL、加 tb、上板抓包、推送前都先扫一眼。
> 远程：`git@github.com:Pyzyd/FpgaCar.git`，唯一集成分支 `main`。

## 1. 一句话原则

**只提交「输入」，不提交「输出」。** 判据：能由仓库内文件重新生成、或可随时重新采集的东西，一律不入库。

所以「仿真文件」其实**是入库的**：18 个 `sim/*_tb.v` 全部被跟踪，`tools/` 下 16 个正式脚本也都在库里。
不入库的是**仿真产物**（`*.vvp`、`.scratch/`、`_sim/`）和**上板抓包数据**（`data/`）——前者由 tb 重编即得，后者随时能重抓。

## 2. 入库 / 不入库对照

| 分类 | 路径 | 处理 | 理由 |
|---|---|---|---|
| 设计源码 | `src/*.v` | ✅ 必交 | 综合输入 |
| 仿真源码 | `sim/*_tb.v` | ✅ 必交 | 回归输入；**不要用 Efinity 的 Import Design 导进工程**（会把 tb 当设计综合） |
| 工程配置 | `FpgaCar.xml` / `FpgaCar.peri.xml` / `FpgaCar.sdc` | ✅ 必交 | 引脚 / 电平 / 时序约束的**唯一真源** |
| 工具脚本 | `tools/*.py` / `*.sh` / `*.bat`（无 `_` 前缀） | ✅ 必交 | 可复现的抓包、烧板、回归流程 |
| 文档 | `PROJECT_PLAN.md` / `CONTRIBUTING.md` / `docs/` | ✅ 必交 | 设计决策与接线结论 |
| 规则文件 | `.gitignore` / `.gitattributes` | ✅ 必交 | 边界本身要版本化 |
| 仿真产物 | `*.vvp`、`.scratch/`、`_sim/` | ❌ 忽略 | `iverilog` 重编即得；`.scratch/` 曾误提交 `_sim/patch_*.py` |
| Efinity 产物 | `outflow/`、`work_syn/`、`work_pnr/`、`ooc/`、`.dide/`、`*.bit`/`*.hex`/`*.rpt`/`*.log` | ❌ 忽略 | 由 `src` + 配置文件重建；`outflow/` 16M、每次编译都变 |
| 抓包数据 | `data/`、`_cap*.csv`、`_*.csv` | ❌ 忽略 | 可重抓，体积大且每次不同 |
| 临时脚本 | `tools/_*.py` | ❌ 忽略 | 前缀 `_` = 一次性探测；要长期用就改名去掉下划线 |
| 烧录配置 | `_jtag.jcf` | ❌ 忽略 | 本机路径相关 |

**引脚改动特别规则**：`outflow/FpgaCar.lpf` 与 `outflow/FpgaCar.pinout.csv` 是派生报告（每次编译 `Date` 头会变），不入库。
改管脚 / 电平后，除提交 `FpgaCar.peri.xml` 外，**必须同步更新 `PROJECT_PLAN.md` 的接线表**，保证没装 Efinity 的机器也能查到 `i2c_scl → E3 / GPIOL_N_13`、`i2c_sda → F3 / GPIOL_P_13` 这类结论。

**位流归档**：`*.bit` / `*.hex` 不进 git。赛前把最终位流单独拷到 U 盘，或作为 GitHub Release 附件归档，并在 `PROJECT_PLAN.md` 记下对应的 commit hash。

## 3. 换行符

`.gitattributes` 统一 `* text=auto eol=lf`，覆盖 Windows 全局 `core.autocrlf=true`，
消除每次提交刷屏的 `warning: LF will be replaced by CRLF`，并保证跨平台克隆字节一致。
`.xlsx` / `.bit` / `.png` 等显式标 `binary`。**不要靠改全局 `core.autocrlf` 解决**，那只对本机有效。

## 4. 提交前检查清单

1. `git status --short` —— 确认改动都在预期路径，**没有** `outflow/`、`data/`、`.scratch/`、`*.vvp`、`*.bit`。
2. `git diff --check` —— 无尾随空格 / 冲突标记。
3. `tools/run_regression.sh` —— 全量 18 个 tb 必须全绿（约 35 s）。只改文档时可跳过，但**改 `src/` 必跑**。
4. `git add -A && git commit`。

提交消息沿用现有风格：

```
模块：一句话说清做了什么

为什么改（现场现象 / 根因，1–3 行）。

- 文件A: 具体改动
- 文件B: 具体改动
```

- 主题行中文、≤ 50 字，用「模块：动作」而非「update」「fix bug」。
- 正文写 **why**，diff 自己会说明 what。
- 一个提交一件事：RTL 改动、tb 用例、文档更新可以同一提交（它们是一个完整变更），但不要掺进无关的阈值调优。
- 不提交 WIP / 调试用 `$display` / 临时改的 `SCL_FREQ`。

## 5. 推送规则

1. **唯一集成分支 `main`**，直接提交到 `main`（单人开发）。禁止 `--force` / `--force-with-lease`。
2. 推送前：`git fetch origin` → 看 `git status -sb` 的 ahead/behind；落后就先 `git pull --rebase`，**不要在落后时直接 push**。
3. 推送前必跑 `tools/run_regression.sh`。建议启用自动门禁（一次配置）：
   ```bash
   git config core.hooksPath tools/hooks
   ```
   之后每次 `git push` 会自动跑全量回归，不过就拦下。紧急纯文档推送可 `FPGA_CAR_SKIP_SIM=1 git push` 显式跳过。
   **Windows 注意（两个坑，本仓库都已规避）**：
   - hook 脚本必须用 `#!/bin/bash`（或 `#!/bin/sh`）开头。**不要用 `#!/usr/bin/env bash`**：
     Git for Windows 执行 hook 时会去 exec `env`，报
     `env: failed to run command '.../pre-push': Permission denied`——推送被拦但回归根本没跑，
     极易误判成「回归失败」。相对/绝对 `core.hooksPath` 都不是问题，shebang 才是。
   - 脚本必须带可执行位。仓库里已用 `git update-index --chmod=+x` 把 `tools/hooks/pre-push` 与
     `tools/run_regression.sh` 固化成 `100755`；新建脚本记得同样执行。
4. `git push origin main` 后确认 `git status -sb` 显示 `main...origin/main` 无 ahead。

## 6. 常用命令

```bash
# 全量回归 / 单 tb 回归
tools/run_regression.sh
tools/run_regression.sh oled_driver_tb color_seq_tb

# 上板抓包（输出自动落 data/，不入库）
python tools/cap.py
python tools/grab_frame.py

# 提交 + 推送
git status --short && git diff --check
tools/run_regression.sh
git add -A && git commit
git fetch origin && git push origin main
```

> iverilog 默认找 `C:/iverilog/bin`（见 `PROJECT_PLAN.md:141`）；换机器可设 `IVERILOG_BIN=<dir>`。
