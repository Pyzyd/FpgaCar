# FpgaCar 项目分析报告

> 分析对象：`D:\VF-Ti60F225_HDK_V2.1_20251009\FpgaCar`
> 版本：本地 HEAD = `origin/main` = `11e1261`（与 GitHub 最新一致，无领先/落后提交）
> 分析日期：2026-11-22
> **注意：本文是那一刻的快照。** 之后代码继续演进（新增速度环 `speed_pid`、OLED 调试区改文字布局、侧绕改五段弧线、基础占空比降到 480），文中「26 个模块 / 24 个 tb / 11e1261」等数字与当前 HEAD 已不一致，最新状态以 `PROJECT_PLAN.md` 为准。
> 方法：三路并行源码审查（RTL 核心 / RTL 显示与摄像头 / K230 视觉）+ 逐条人工复核 + 真实跑通回归门禁

---

## 一、结论速览

这是一个**工程素养明显高于同类的 RoboMaster/智能车 FPGA 参赛项目**：7437 行 Verilog 拆成 26 个单一职责模块、4428 行仿真测试台覆盖 24 个模块、4012 行 K230 视觉代码，注释里甚至记录了历史 bug 的成因。回归门禁 **24/24 真实通过**（详见附录 A），基线是健康的。

但**当前位流离赛题满分差距很大**，根本原因不是代码写错，而是**战略层面的三项空白 + 两处静默失效**：

| 赛项 | 分值 | 当前状态 | 判断 |
|---|---|---|---|
| 循迹 | 20 | 能跑，但仅到"通过两个弯"的门槛 | 部分得分 |
| 避障 | 20 | 有完整五段绕障状态机，但**违反"不得大转弯"细则** | 有风险 |
| 交通牌 | 25 | 只做"原地盲转 0.7 s"，不是"驶入对应支路" | 大幅失分 |
| 颜色顺序 | 20 | 四槽位齐备，但**受双重截断，实际可能一个都发不出** | 可能 0 分 |
| 倒车入库 | 15 | **完全没有实现** | 0 分 |

最要命的一条：**当前位流里颜色和交通牌两路的信号源存在配置冲突**（详见 P0-1），意味着 45 分对应的功能可能根本没有输入。

---

## 二、项目结构

```
FpgaCar/
├── src/            26 个 .v，7437 行    RTL 主体（顶层 FpgaCar.v + 25 个子模块）
├── sim/            24 个 .v，4428 行    每个模块配一个独立测试台
├── k230/           38 个 .py，4012 行   K230 视觉端（识别 + 串口协议）
├── tools/          14 个脚本           回归、烧录、串口监视、位图生成
├── docs/           16 个文档           接线图、GPIO 契约、引脚分配
├── bench/          台架测试
├── ip/ ooc/ work_syn/ work_pnr/ outflow/   综合与布局布线产物
├── FpgaCar.xml / FpgaCar.peri.xml / FpgaCar.sdc   工程与约束
├── PROJECT_PLAN.md 项目主文档（含赛题评分细则 §3.30）
└── CONTRIBUTING.md
```

顶层 [src/FpgaCar.v](src/FpgaCar.v) 用一组 `localparam` 做功能裁剪（`:127` `USE_CAMERA`、`:133` `USE_K230`、`:320` `USE_IR`、`:328` `USE_ULTRA`、`:472` `g_lcd`、`:769` `g_oled`），这是很好的设计——**但当前参数组合与设计文档矛盾**，见 P0-1。

---

## 三、P0 级问题（会导致上板功能错误或直接丢分）

### P0-1 颜色与交通牌两路信号源配置冲突，45 分可能无输入

**位置**：[src/FpgaCar.v:127](src/FpgaCar.v#L127) `localparam USE_CAMERA = 1'b0;` 与 [src/FpgaCar.v:133](src/FpgaCar.v#L133) `localparam USE_K230 = 1'b1;`

**现象**：颜色源被切到 K230（`:731` `wire [2:0] color_in_mux = USE_K230 ? k_color[2:0] : cam_color;`），转向源也被切到 K230（`:378` `wire [2:0] dir_evt_mux = USE_K230 ? k_dir : 3'd0;`）。若 K230 未实际接线/未上电：
- `k230_link` 收不到 strobe → `k_color` 恒 0 → `color_seq` 写条件 `new_color && color_in != 0`（[src/color_seq.v:63](src/color_seq.v#L63)）永不成立 → **颜色顺序 20 分全丢**；
- `dir_evt` 恒 0 → 交通牌只剩 `car_fsm` 的拐角兜底左转 → **交通牌 25 分基本全丢**；
- `:766` `wire k230_off = USE_K230 & ~k_alive;` → OLED 上**常亮一个掉线叉号**。

**与文档的直接矛盾**：[PROJECT_PLAN.md:2456](PROJECT_PLAN.md#L2456) 明确写 "`USE_K230` 保持 `1'b0`，`k230_off` 恒 1"，而代码是 `1'b1`。`:2454` 还写明"K230 相关代码由他人在另一个 git 分支完成，暂不合并；本分支只做非视觉部分"。**代码已经和这条决策脱节了。**

**注意**：这不是说 `USE_K230=1` 本身是 bug。若 K230 已并入，`1'b1` 是正确选择，此时真正的问题变成"文档过期"。**必须先定死这个开关到底该是什么**，因为它是"无论怎么调 PID 都拿不到分"的唯一根因，优先级高于所有 RTL 细节。

**建议**：
1. 先确认 K230 是否已物理接入本车。未接 → 改回 `1'b0`，并在报告层面承认"当前位流无颜色能力"；已接 → 同步更新 PROJECT_PLAN.md:2456 与 :2145 的表格。
2. 无论哪种选择，都应把 `k230_off` 从"OLED 画叉"升级为**串口告警 + OLED 状态行**，否则现场只看到叉号不知道是没接线还是协议错。

---

### P0-2 菱形"连续两次左转"的第二张牌，在转向执行期间被静默丢弃

**位置**：[src/car_fsm.v:257-258](src/car_fsm.v#L257-L258)

```verilog
if ((dir_evt == 3'd1 || dir_evt == 3'd2) &&
    ((TURN_WAIT_FOR_CORNER == 0) || !turning)) begin
    turn_req  <= 1'b1;
```

**现象**：顶层 `TURN_WAIT_FOR_CORNER = USE_K230 = 1`（[src/FpgaCar.v:412](src/FpgaCar.v#L412)），所以 `!turning` 条件生效。转向最长 1100 ms（`:404` `.TURN_MS(1100)`），而菱形要求左转两次、两张牌物理上紧挨着——K230 识别第二张牌时，车正在执行第一次转向。此时到达的 `dir_evt` **既不锁存也不排队，直接丢弃**；而 `dir_evt` 是单拍脉冲（[src/k230_link.v:161-163](src/k230_link.v#L161-L163) 每拍默认清零），错过即永久丢失。

**现场表现**："第一次左转正常，转完直接冲出去"——而且这个现象与循迹参数问题高度混淆，极难定位。

**建议**：引入二级寄存器 `pending_turn`，在当前转向结束的那一拍（`car_fsm.v:361-366` 的 `turn_cnt<=1`）再生效。**不要**简单地把 `!turning` 删掉——那会让正在进行的转向中途反向（`S_RUN` 的 `turning` 分支正在用 `turn_left` 决定方向，`:353-354`）。

---

### P0-3 超声波失效被解释成"前方无障碍"，车全速撞上去

**位置**：[src/FpgaCar.v:330](src/FpgaCar.v#L330)、[src/car_fsm.v:392-406](src/car_fsm.v#L392-L406)

```verilog
// src/FpgaCar.v:330
wire hc_near  = (dist_cm != 16'hFFFF) && (dist_cm <= OBSTACLE_CM);
// src/FpgaCar.v:337
wire obstacle = (USE_ULTRA ? hc_near : 1'b0) | (USE_IR & ir_det);
```

`hc_sr04` 的所有失败分支都写 `dist_cm = 16'hFFFF`（[src/hc_sr04.v:127](src/hc_sr04.v#L127) 回波超时、`:139` 超量程），顶层把这个"无效"解释成"无障碍"。而 `USE_IR = 1'b0`（`:320`），红外冗余也被关掉，`obstacle` 只剩超声一路，**失效方向是不安全的**。

另外 `ECHO_WAIT_US = 5_000`（`hc_sr04.v:27`，5 ms）内没等到上升沿就判 FFFF，而正常 4 m 量程需要约 23 ms 往返，**这个窗口本身就会把远处目标误判成"无回波"**。

**叠加风险**：`S_RUN` 里转向请求排在障碍前面（[src/car_fsm.v:392](src/car_fsm.v#L392) 的 `if (turn_req ...)` 在 `:402` 的 `else if (obstacle)` 之前），拐角处同时有牌和障碍时会选择原地转而不是先停。注意 `S_LOST` 里顺序是对的（`:421` 在 `:430` 之前），只有 `S_RUN` 反了。

**建议**：
1. 加 `ultra_dead` 判据：连续 N 次 `valid && dist_cm == 16'hFFFF` 就置位，并把 `obstacle` 改成 `obstacle = ultra_dead | hc_near | ...`；
2. `ECHO_WAIT_US` 提到 25_000 以上，或区分"5 ms 内无上升沿"（真没接）与"有上升沿但超时"（超量程）；
3. 把 `else if (obstacle)` 提到 `S_RUN` 最前。

---

### P0-4 色序只能发出前 4 次，且面板清空与 K230 永久不同步

**位置**：[k230/multi_tracker.py:226](k230/multi_tracker.py#L226)、[k230/field_vision.py:37-39](k230/field_vision.py#L37-L39)

```python
# k230/multi_tracker.py:226-230
included=len(self.sequence)<4
if included:
    self.sequence.append(t['color'])
events.append({..., 'included':included, 'epoch':self.epoch})
```

```python
# k230/field_vision.py:37-39
for passage in tracking['events']:
    if passage['included']:
        events.append({'kind':'color','label':passage['label'],'track':passage['track']})
```

**现象**：`included` 这个标志**同时决定"是否记入序列"和"是否上报给 FPGA"**。序列满 4 个后 `included=False`，事件不再产生，`field_vision.py:116-117` 也就不发 `link.send()`。

**灾难性后果**：RTL 侧清空是独立的——[src/car_panel.v:60](src/car_panel.v#L60) `clear_result <= clear_press`，[src/FpgaCar.v:750](src/FpgaCar.v#L750) `.clr (clear_result)` 只清 `color_seq` 四个槽位。**两端没有任何回传通道**。所以按一次面板清空后，K230 的 `sequence` 仍是 4，此后整场不再发任何色块事件。更糟的是起跑阶段的 4 次误检同样会吃满配额，**只能断电重来**。K230 侧没有任何地方在场地入口复位跟踪器（`reset()`/`pause()` 调用点只有 [k230/main.py:432,440,453](k230/main.py#L432) 的连拍/浏览入口）。

**建议**：解除 K230 侧的硬截断——`included` 只决定是否写入 `sequence` 供屏幕显示，不决定是否上报。上报的 4 个上限交给 RTL 的 `cnt < 4` 把关（[src/color_seq.v:63](src/color_seq.v#L63) 已有该条件）。这是一行改动，收益是让颜色项从"可能 0 分"变成"能持续工作"。

---

### P0-5 协议里的"清空顺序/新一圈"命令两端都没实现

**位置**：[k230/gpio_link.py:11](k230/gpio_link.py#L11)、[src/k230_link.v:224-225](src/k230_link.v#L224-L225)、[src/FpgaCar.v:374](src/FpgaCar.v#L374)

```python
# k230/gpio_link.py:11
EVENTS = {1:(2,1), 2:(2,2), 3:(1,1), 4:(1,3), 5:(1,4), 6:(1,2)}   # 只有 1..6
```

协议文档（[src/k230_link.v:12](src/k230_link.v#L12)）写明 `CAT=011 命令 VAL=1清空顺序 2新一圈`，接收端 `:224-225` 也确实会产出 `cmd_evt` 的 bit0/bit1。但：
- **K230 侧从不发送 CAT=3**（`EVENTS` 表里没有，只有心跳 `_send(7,1)` 在 `:89`）；
- **RTL 侧 `k_cmd` 没有消费者**：只出现在 [src/FpgaCar.v:374](src/FpgaCar.v#L374) 声明、`:715` 连到 `k230_link`、`:723` `USE_K230=0` 时打常量，全文再无读取。`color_seq.clr` 接的是面板的 `clear_result`。

即"解析、去重、校验全跑完，结果被丢掉"。这也是 P0-4 无法自我恢复的结构性原因——**协议里本来设计了解药，但两端都没接**。

**建议**：`k_cmd[0]` 或进 `clear_result`，并在 K230 侧加"进入场地/新一圈"时发送 CAT=3。这是修 P0-4 的配套动作。

---

## 四、P1 级问题（边界条件 / 竞态 / 参数隐患）

### RTL 核心

| # | 位置 | 问题 |
|---|---|---|
| P1-1 | [src/car_fsm.v:631-633](src/car_fsm.v#L631-L633) | 避障重试用尽进 `S_STOP` 但**没置 `final_stop`**，障碍一消失就按 `S_RUN` 用过期 PID 盲目前冲，直到丢线。建议进 `S_STOP` 前若 `!on_line` 改走 `S_LOST`（与 `:645` 一致） |
| P1-2 | [src/car_fsm.v:164](src/car_fsm.v#L164) | `AVOID_ROUTE_EN==0` 时 `avoid_start_left = !last_pos_neg && (true)`，`AVOID_FIXED_RIGHT` 被短路失效。当前顶层 `AVOID_ROUTE_EN=1` 未暴露 |
| P1-3 | [src/car_fsm.v:290-293](src/car_fsm.v#L290-L293) | `turn_request_left` 只在 `TURN_WAIT_FOR_CORNER != 0` 时递减，该参数为 0 时 `TURN_REQUEST_MS` 变成死参数 |
| P1-4 | [src/car_fsm.v:570-590](src/car_fsm.v#L570-L590) | `S_AVOID_PROBE` 五段绕障的 `ms_cnt` 只在部分分支清零，跨段不复位会让 `AVOID_TURN_IN_MS` 判定提前。建议每段切换处无条件 `ms_cnt <= 0` |
| P1-5 | [src/encoder_dec.v:74](src/encoder_dec.v#L74) | `direction` 与 `step` 同拍更新，而 `speed_meter` 同拍读两者（[src/speed_meter.v:43-45](src/speed_meter.v#L43-L45)）→ **方向反转的首个脉冲按旧方向计数**，净步数错 1。`position` 不受影响。建议改成组合输出 |
| P1-6 | [src/track_pid.v:63-68](src/track_pid.v#L63-L68) | `err_d` 最大 14 × `D_GAIN=40` = ±560，而 `sum_raw` 限幅 ±600 → **单靠 D 项就能打到满偏**，P 项被淹没。宽黑结束重新压线时 `pos` 从 0 跳到 ±7 会打出尖峰。建议 `d_term` 单独限幅 |
| P1-7 | [src/k230_link.v:82-86](src/k230_link.v#L82-L86) | `stb_rise` 对应 `k230_stb` 的 t-1，采到的 `d_s1` 是 `k230_d` 的 t-2 → **数据比选通晚 2 clk（83 ns）**。现依赖 K230 侧"先写数据→sleep 1ms→拉 STB"的隐式约定。改成同时写会稳定采到旧值，且旧值合法时会被当"两遍一致"采纳，`err_cnt` 上看不出来。建议在 strobe 上升沿拍直接采 `d_s0` |
| P1-8 | [src/k230_link.v:186](src/k230_link.v#L186) | 符号语义完全依赖"跨帧恰好 2 个 000"。K230 侧若写成"每条消息前只发一个 000"，CAT 的 gap 只有 1 → 被当数值 → **整条链路 CAT/VAL 互换**，表现为 `err_cnt` 飞涨、零事件 |
| P1-9 | [src/track_line.v:190-191](src/track_line.v#L190-L191) | `cnt <= cnt_w[3:0]; wide <= wide_now;` 同时钟沿更新，但 `wide_now` 由当拍组合逻辑算出 → 外部看到 `cnt=5` 但 `wide=0` 的不一致（1 clk） |
| P1-10 | [src/FpgaCar.v:399](src/FpgaCar.v#L399) | `.SEARCH_FAIL_TO_IDLE(0)` + 拐角兜底 → **一次误判丢线就是永久停车**（`final_stop` 只能靠面板 K2 或断电恢复）。建议只在连续两次找线失败后置位 |
| P1-11 | [src/i2c_timing_ctrl_16bit.v:160](src/i2c_timing_ctrl_16bit.v#L160) | **SCCB 配置忽略从机应答**：`if(i2c_transfer_end)    //   & ~i2c_ack)` 应答检查被注释掉；且 `:351` `i2c_ack <= (i2c_ack1 \| i2c_ack2 \| i2c_ack3);// \| i2c_ack4 );` **漏掉 ack4**。相机未上电/排线松/地址错（`DEV_ADDR=8'h78`，[src/FpgaCar.v:513](src/FpgaCar.v#L513)）时整张表"成功"跑完、`i2c_config_done` 照常置 1，**预览全黑却无任何线索**。该路径当前活跃（`USE_LCD_PREVIEW=1` → `g_lcd` → `cam_sccb_cfg`） |

### K230 视觉

| # | 位置 | 问题 |
|---|---|---|
| P1-12 | [k230/field_vision.py:87-92](k230/field_vision.py#L87-L92) | **GPIO 初始化失败只打印一行，比赛照跑**：`except Exception as exc: print('[GPIO] disabled:',exc)` → `link` 保持 None，主循环继续。Ti60 收不到任何信号，车按 `car_fsm` 拐角兜底跑。触发概率不低：`gpio_link.py:36-41` 在引脚被占用时 raise RuntimeError。且 `config.py:29` `GPIO_ENABLE = False` 被 `field_startup.py:9` `main(send_gpio=True)` 绕过——**两套开关并存** |
| P1-13 | [k230/turn_verify/turn_detector.py:70-72](k230/turn_verify/turn_detector.py#L70-L72) | **转向检测全画幅搜索**：`find_blobs([BLUE_LAB], x_stride=2, y_stride=2, pixels_threshold=110, area_threshold=300, merge=False)` 没传 `roi`，而色块侧有 `FIELD_COLOR_ROI`。后果：本帧最贵操作压制帧率；远处蓝物进候选。配合 `CONFIRM_FRAMES=4` 在 10 FPS 下需约 300 ms 确认 |
| P1-14 | [k230/tools/replay_field_vision.py](k230/tools/replay_field_vision.py) | 依赖 SciPy，本机 `ModuleNotFoundError` → README 中 **597 张实拍回放结论未复核** |
| P1-15 | [k230/tools/check_gpio_link.py:140](k230/tools/check_gpio_link.py#L140) | **仓库内存在失败测试**：`Ran 6 tests, 1 FAILED`（`'GPIOL_N_17' unexpectedly found in [...55 allocated pins...]`）。根因是文档滞后：[docs/k230_gpio_contract.json:22](docs/k230_gpio_contract.json#L22) 仍写 `"lcd_status": "reserved_only_not_added_to_rtl_or_peri"`，而 `FpgaCar.peri.xml:169-186` 已绑定 LCD 五根 SPI |
| P1-16 | [k230/arrow_core.py](k230/arrow_core.py) 等 | **模块双份同名实现**：`arrow_core.py` ≡ `turn_verify/turn_shape.py`、`arrow_templates.py` ≡ `turn_verify/turn_templates.py`，内容完全相同；靠 `field_startup.py:4-5` 的两条 `sys.path` 区分。维护时改一处漏一处 |

---

## 五、P2 级问题（可读性 / 资源 / 一致性）

- [src/FpgaCar.v:477](src/FpgaCar.v#L477) 注释写"双缓冲 + request/ack 握手"，实际 [src/ov5640_preview_frame.v:48](src/ov5640_preview_frame.v#L48) 只有一块 `frame[0:FRAME_SAMPLES-1]`，是**单缓冲 + 4 相所有权交接**。逐拍核对不会撕裂，但相机低于 ~8 fps 时屏会周期性闪测试图。
- [src/oled_driver.v](src/oled_driver.v) 调试区注释过期：`:700` 说 368 字节、`:732` 说 432 字节，实际 `DK_END = 9'd472`（`:405`）。**当前未越界，但段 4 上界已贴住 `fb[0:1023]` 最后一格，再右扩一格就越界**。
- [src/FpgaCar.v:770](src/FpgaCar.v#L770) 的 `oled_ack_err` / `oled_nack_seen` / `oled_frame_done` **无任何消费者**，而 [src/oled_driver.v:100-102](src/oled_driver.v#L100-L102) 注释正说这两个信号用来区分"总线通了但屏没显示"。
- [src/color_seq.v:12](src/color_seq.v#L12) 注释仍写"clr 当前顶层接常量 0"，实际 [src/FpgaCar.v:750](src/FpgaCar.v#L750) 已接 `clear_result`。
- [src/track_pid.v:23](src/track_pid.v#L23) `DUTY_MAX` 声明后从未使用；`:67-68` `err * P_GAIN` 在 32 位乘法后截断回 16 位，改大 `P_GAIN` 会静默溢出。
- [src/speed_meter.v:43-53](src/speed_meter.v#L43-L53) 窗口边界的最后一个脉冲会被丢弃（`if (step)` 与窗口清零同拍时后者胜出），误差 0.05% 量级。
- [src/encoder_dec.v:29](src/encoder_dec.v#L29) `position` 端口是无符号，但注释写"有符号里程"，倒车越过 0 会回绕到 42 亿。
- [src/hc_sr04.v:72](src/hc_sr04.v#L72) `echo_us` 18 位而 `MEAS_MAX_US` 只需 15 位，`dist_mul` 用 `{14'd0, echo_us} * 16'd1130` 会让综合推断出比实际更宽的乘法器。
- [src/car_fsm.v:416-417](src/car_fsm.v#L416-L417) `S_LOST` 里 `duty_l <= pid_l` 未加 `if (!dead)`，目前被 `en` 表达式掩盖。
- [src/car_fsm.v:457-462](src/car_fsm.v#L457-L462) 普通丢线也会让 OLED 报"正在左转/右转"1.5 s。
- [k230/album.py:11](k230/album.py#L11) `if not (os.stat(path)[0] & 0x4000)` 可读性差；[k230/main.py:440,453](k230/main.py#L440) 调 `tracker.pause()` 而 `field_vision.py` 无对应处理。

---

## 六、已确认无问题的部分（避免重复排查）

- **[src/pwm_gen.v](src/pwm_gen.v)**：`CNT_MAX=1200` 与 11 位计数器匹配，`cmp = (cnt < duty) | (duty > CNT_MAX[10:0]-1)` 正确保证 100% 直通与恒低，`pwm = en & cmp` 门控正确。
- **[src/color_seq.v](src/color_seq.v)**：去重逻辑正确，空槽为 0 且 `color_in != 0` 不会误判重复，`cnt < 4` 阻止覆盖。
- **[src/encoder_dec.v](src/encoder_dec.v)**：正交解码表四倍频正确，"两相同跳"被显式排除为抖动。
- **SPI/ST7789**：mode0 时序正确（`:252` 用旧值判下降沿）；抬 CS 后回 INIT_WRITE 不漏拉低。
- **uart_tx**：波特率误差 +0.16%；`uart_report` 两行报文无空洞无越界。
- **计数器饱和**：`car_panel` 消抖计数、`dvp_capture` 计数、`ov5640_preview_frame` 坏行计数均有饱和保护，**不会永久卡死**。
- **内存边界**：预览地址 `(row<<7)+(row<<5)=row*160` 读写一致；OLED 显存写点全部 < 1024，渲染/推屏严格互斥。
- **K230 侧工程质量**：被积压/噪声/抖动误触发的边界情况都有显式状态（`blocked`、`uncertain`、`ambiguous`），写卡失败不冒泡、不删旧数据。

---

## 七、赛题差距分析

赛题（[PROJECT_PLAN.md:2401-2450](PROJECT_PLAN.md#L2401) §3.30）：场地约 4.5 m × 3.0 m，四角 R=30 cm 圆角；线宽 **1~2 cm**（现场实拍标定 1.3 cm）；障碍 10 cm 立方体、避让区 ±50 cm 且**须自主回到原线路**；颜色块距线 25 cm；车库净尺寸 **40 cm × 40 cm**、**车尾先入**并**停稳 ≥5 秒**。

| 赛项 | 分值 | 细则要求 | 当前实现 | 差距 |
|---|---|---|---|---|
| 循迹 | 20 | 通过前两个弯道才得分 | 有完整 PID + 丢线搜索 | 只到门槛，宽黑分岔口可能冻结 `pos` |
| 避障 | 20 | 绕开 20 / 仅绕开 10 / 碰障碍 −10 | 五段绕障（`BY_ALIGN→BY_PASS→BY_OUT→BY_ALIGN→BY_TURN_IN`） | **违反"不得大转弯"**，且 P0-3 失效方向不安全 |
| 交通牌 | 25 | **驶入对应支路** | 锁存 `dir_evt` 后原地盲转 (`car_fsm.v:172-182`，`turn_cnt<=TURN_MS`) | 不是"驶入支路"；分岔口两条线都在时 `S_LOST` 不会触发；P0-2 还会吞掉第二张牌 |
| 颜色顺序 | 20 | 每对 1 个 5 分 | 四槽位 + 去重齐备 | P0-4 双重截断 → 可能一个都发不出 |
| 倒车入库 | 15 | 入库停 5 s 得 15，投影未全进 10 | **完全没有** | `car_fsm.v` 8 个状态（IDLE/RUN/LOST/SEARCH/STOP/AVOID_BACK/AVOID_TURN/AVOID_PROBE）里无找库/对准/倒车/停稳路径 |

---

## 八、建议的修复优先级

**第一步（决定成败，半天内可完成）**
1. 定死 `USE_K230` / `USE_CAMERA` 组合，并同步文档（P0-1）。这是唯一"无论怎么调 PID 都拿不到分"的问题。
2. 解除 K230 侧色序硬截断（P0-4，一行改动）+ 接通 `k_cmd`（P0-5）。
3. 修菱形第二次转牌丢弃（P0-2，加 `pending_turn` 二级寄存器）。

**第二步（安全与稳定，一天）**
4. 超声波失效判据 + `obstacle` 提到最高优先级（P0-3）。
5. 修 `S_AVOID` 用尽后的盲目前冲（P1-1）、`d_term` 限幅（P1-6）、编码器方向拍（P1-5）。
6. SCCB 恢复 ACK 检查（P1-11），把 `i2c_ack` 引到串口/LED。

**第三步（拿分扩展，工作量最大）**
7. 交通牌改"目标偏移 + 主动拉线"（25 分）。
8. 倒车入库（15 分，需新增状态与车库检测）。

**随时可做**
9. 清理 P2 的注释过期与失联信号；修 `check_gpio_link.py` 的文档滞后。

---

## 附录 A：回归门禁实况（2026-11-22 实跑）

`tools/run_regression.sh` 直接跑会报 24 个 tb 全 COMPILE_FAIL——**这是假失败**：脚本把 vvp/clog/olog 全写到 `.scratch/`，本会话沙箱对该目录不可写，报 `Permission denied`。把判据复制到可写目录后重跑，真实结果：

```
car_fsm_tb             OK   PASS=85   ALLPASS=1  FAIL=0  TO=0  rc=0
oled_driver_tb         OK   PASS=22   ALLPASS=0  FAIL=0  TO=0  rc=0
color_detect_tb        OK   PASS=21   ALLPASS=1  FAIL=0  TO=0  rc=0
bypass_rejoin_tb       OK   PASS=19   ALLPASS=1  FAIL=0  TO=0  rc=0
st7789_panel_tb        OK   PASS=17   ALLPASS=1  FAIL=0  TO=0  rc=0
color_seq_tb           OK   PASS=13   ALLPASS=0  FAIL=0  TO=0  rc=0
FpgaCar_tb             OK   PASS=12   ALLPASS=0  FAIL=0  TO=0  rc=0
car_panel_tb           OK   PASS=11   ALLPASS=0  FAIL=0  TO=0  rc=0
encoder_dec_tb         OK   PASS=9    ALLPASS=0  FAIL=0  TO=0  rc=0
i2c_master_tb          OK   PASS=8    ALLPASS=0  FAIL=0  TO=0  rc=0
track_line_tb          OK   PASS=8    ALLPASS=0  FAIL=0  TO=0  rc=0
track_pid_tb           OK   PASS=8    ALLPASS=0  FAIL=0  TO=0  rc=0
cam_probe_tb           OK   PASS=7    ALLPASS=0  FAIL=0  TO=0  rc=0
frame_snap_tb          OK   PASS=6    ALLPASS=0  FAIL=0  TO=0  rc=0
cam_sccb_cfg_tb        OK   PASS=5    ALLPASS=0  FAIL=0  TO=0  rc=0
uart_tx_tb             OK   PASS=5    ALLPASS=0  FAIL=0  TO=0  rc=0
dvp_capture_tb         OK   PASS=4    ALLPASS=0  FAIL=0  TO=0  rc=0
hc_sr04_period_tb      OK   PASS=4    ALLPASS=1  FAIL=0  TO=0  rc=0
hc_sr04_tb             OK   PASS=4    ALLPASS=0  FAIL=0  TO=0  rc=0
speed_meter_tb         OK   PASS=4    ALLPASS=0  FAIL=0  TO=0  rc=0
pwm_gen_tb             OK   PASS=3    ALLPASS=0  FAIL=0  TO=0  rc=0
turn_at_corner_tb      OK   PASS=3    ALLPASS=0  FAIL=0  TO=0  rc=0
uart_report_tb         OK   PASS=0    ALLPASS=1  FAIL=0  TO=0  rc=0
k230_link_tb           OK   PASS=16   ALLPASS=1  FAIL=0  TO=0  rc=0   ← 见下
----------
total=24  failed=0
```

**k230_link_tb 说明**：脚本首轮报 FAIL(rc=1) 是因为 [sim/k230_link_tb.v:110](sim/k230_link_tb.v#L110) 硬编码 `$dumpfile(".scratch/k230_link_tb.vcd")`，同属写权限问题。把路径改到可写目录后重跑，**16 项检查全部 PASS，末尾输出 `ALL PASS: k230_link`**（4 种颜色编码转换、`link_alive=1`、方向左/直、命令清空顺序/新一圈、心跳续活、两遍不一致拒绝且 `err_cnt=1`、000 分隔符无事件、失步后 3 条消息内自恢复、掉线超时归 0、新消息恢复）。

**结论：24/24 测试台真实全部通过，代码基线健康。**

唯一编译警告：`src/I2C_OV5640_1280720_Config.v:302: warning: Extra digits given for sized hex constant`（24 个 tb 都报，是该文件本身的写法问题，不影响功能）。

---

## 附录 B：验证边界

以下项目受环境限制**未能验证**，报告中不视为缺陷：
- `k230/tools/check_recorder.py`、`check_analysis.py`、`check_prototype.py`：因沙箱临时目录不可写（`PermissionError: [WinError 5]`）无法判定。
- `replay_field_vision.py` 依赖 SciPy 未安装，README 中 597 张实拍回放结论未复核。
- 所有结论均基于静态代码审查 + 仿真，**未经上板实测**。
