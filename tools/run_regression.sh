#!/bin/bash
# tools/run_regression.sh —— 提交 / 推送前的全量回归门禁
#
# 用法：
#   tools/run_regression.sh                    # 跑全部 sim/*_tb.v
#   tools/run_regression.sh oled_driver_tb     # 只跑指定 tb（开发时用，可传多个）
#
# 退出码：0 = 全绿；1 = 有 COMPILE_FAIL / FAIL / TIMEOUT / 静默失败
# 仿真产物统一落在被 .gitignore 忽略的 .scratch/，跑完自动清理。
# iverilog 查找顺序：PATH → C:/iverilog/bin → $IVERILOG_BIN。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if ! command -v iverilog >/dev/null 2>&1; then
    if [ -d /c/iverilog/bin ]; then
        export PATH="/c/iverilog/bin:$PATH"
    elif [ -n "${IVERILOG_BIN:-}" ] && [ -d "$IVERILOG_BIN" ]; then
        export PATH="$IVERILOG_BIN:$PATH"
    fi
fi
if ! command -v iverilog >/dev/null 2>&1; then
    echo "ERROR: 找不到 iverilog。装到 C:/iverilog 或设置 IVERILOG_BIN=<dir>。" >&2
    exit 1
fi

mkdir -p .scratch

# 每次运行用独立后缀：队友并行跑回归时，共用的 _run_<tb>.out 会互相覆盖，
# 表现为 PASS 计数为空、却被误判成通过。$$ 是当前 shell 的 pid。
RUN_ID=$$

tbs=()
if [ "$#" -gt 0 ]; then
    for t in "$@"; do
        t="${t%.v}"; t="${t#sim/}"
        [ -f "sim/$t.v" ] || { echo "ERROR: 没有 sim/$t.v" >&2; exit 1; }
        tbs+=("$t")
    done
else
    for f in sim/*_tb.v; do
        [ -e "$f" ] || continue
        t="${f##*/}"; tbs+=("${t%.v}")
    done
fi

wlog=".scratch/_warnings_${RUN_ID}.log"
rm -f "$wlog"

total=0; failed=0; t0=$(date +%s)
for tb in "${tbs[@]}"; do
    total=$((total + 1))
    vvp=".scratch/_run_${tb}_${RUN_ID}.vvp"
    clog=".scratch/_run_${tb}_${RUN_ID}.compile.log"
    olog=".scratch/_run_${tb}_${RUN_ID}.out"
    rm -f "$vvp" "$clog" "$olog"

    if ! iverilog -g2012 -Wall -s "$tb" -o "$vvp" src/*.v "sim/${tb}.v" >"$clog" 2>&1; then
        printf '%-22s COMPILE_FAIL\n' "$tb"
        sed 's/^/    /' "$clog" | head -8
        failed=$((failed + 1))
        continue
    fi

    # 编译警告不能悄悄扔掉：死寄存器（saw_line）、悬空输入端口（dir_evt）、
    # 未引用参数（DEBOUNCE_N）都只在这里出现。汇总到一处，跑完一起打印。
    grep -E 'warning:' "$clog" 2>/dev/null | sed "s|^|${tb}: |" >> "$wlog"

    s=$(date +%s)
    # 单个 tb 上限：car_fsm_tb 有 7 个实例、含 200 ms 级的长时延用例，
    # 实测约 236 s。早期上限 180 s 会把它的正常完成误判成"静默失败"。
    timeout 420 vvp "$vvp" >"$olog" 2>&1
    rc=$?
    e=$(date +%s)
    # 注意：grep -c 在文件缺失时不打印数字，$() 得到空串，后面的 -eq 会报
    # "integer expected" 并把 status 留在 OK —— 明明没跑成却报"全部通过"。
    # 所以每个计数都必须兜底成 0，绝不允许空串流进算术比较。
    np=$(grep -c 'PASS:' "$olog" 2>/dev/null); np=${np:-0}
    # 'ALL ?PASS' 同时匹配 "ALL PASS" 与 "ALLPASS"：hc_sr04_period_tb 打的是
    # 无空格的 ALLPASS=%0d，早期只抓 'ALL PASS' 时它输出了 ALLPASS=0 仍被判 OK。
    na=$(grep -ciE 'ALL ?PASS' "$olog" 2>/dev/null); na=${na:-0}
    # ALLPASS=0 是明确的失败标记（n<4 这类"根本没测到"的情形只打这一行）
    na0=$(grep -ciE 'ALL ?PASS=0' "$olog" 2>/dev/null); na0=${na0:-0}
    nf=$(grep -c 'FAIL:' "$olog" 2>/dev/null); nf=${nf:-0}
    nt=$(grep -c 'TIMEOUT' "$olog" 2>/dev/null); nt=${nt:-0}

    # 注意：uart_report_tb 只打印 "ALL PASS"、没有 PASS: 行；
    # 因此用「既无 PASS: 也无 ALL PASS」兜底静默失败，不能只看 PASS 计数。
    status="OK"
    if [ "$nf" -ne 0 ] || [ "$nt" -ne 0 ] || [ "$rc" -ne 0 ] \
       || [ "$na0" -ne 0 ] \
       || { [ "$np" -eq 0 ] && [ "$na" -eq 0 ]; }; then
        status="FAIL"; failed=$((failed + 1))
    fi
    printf '%-22s %-4s PASS=%-3s ALLPASS=%-2s FAIL=%-2s TIMEOUT=%-2s %ss\n' \
        "$tb" "$status" "$np" "$na" "$nf" "$nt" "$((e - s))"
    if [ "$status" = "FAIL" ]; then
        grep -E 'FAIL:|TIMEOUT|ERROR|\$finish' "$olog" | head -6 | sed 's/^/    /'
        [ "$np" -eq 0 ] && [ "$na" -eq 0 ] && echo "    (没有任何 PASS 输出，疑似静默失败)"
    fi
    rm -f "$vvp" "$olog" "$clog"
done

printf '%s\n' "------------------------------------------------------------------"
# 警告汇总：不阻塞通过与否，但必须让人看见。只统计、不全量刷屏。
if [ -s "$wlog" ]; then
    nw=$(wc -l < "$wlog" | tr -d ' ')
    echo "编译警告 ${nw} 条（完整清单：${wlog}）："
    sed 's/^/    /' "$wlog" | head -12
    [ "$nw" -gt 12 ] && echo "    ...（其余 $((nw - 12)) 条见文件）"
    echo "------------------------------------------------------------------"
fi

printf '回归汇总：%d 个 tb，%d 失败，耗时 %ss\n' "$total" "$failed" "$(($(date +%s) - t0))"
[ "$failed" -eq 0 ] || exit 1
echo "全部通过"
exit 0
