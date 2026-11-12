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

total=0; failed=0; t0=$(date +%s)
for tb in "${tbs[@]}"; do
    total=$((total + 1))
    vvp=".scratch/_run_${tb}.vvp"
    clog=".scratch/_run_${tb}.compile.log"
    olog=".scratch/_run_${tb}.out"
    rm -f "$vvp" "$clog" "$olog"

    if ! iverilog -g2012 -Wall -s "$tb" -o "$vvp" src/*.v "sim/${tb}.v" >"$clog" 2>&1; then
        printf '%-22s COMPILE_FAIL\n' "$tb"
        sed 's/^/    /' "$clog" | head -8
        failed=$((failed + 1))
        continue
    fi

    s=$(date +%s)
    timeout 180 vvp "$vvp" >"$olog" 2>&1
    rc=$?
    e=$(date +%s)
    np=$(grep -c 'PASS:' "$olog" || true)
    na=$(grep -ciE 'ALL PASS' "$olog" || true)
    nf=$(grep -c 'FAIL:' "$olog" || true)
    nt=$(grep -c 'TIMEOUT' "$olog" || true)

    # 注意：uart_report_tb 只打印 "ALL PASS"、没有 PASS: 行；
    # 因此用「既无 PASS: 也无 ALL PASS」兜底静默失败，不能只看 PASS 计数。
    status="OK"
    if [ "$nf" -ne 0 ] || [ "$nt" -ne 0 ] || [ "$rc" -ne 0 ] \
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
printf '回归汇总：%d 个 tb，%d 失败，耗时 %ss\n' "$total" "$failed" "$(($(date +%s) - t0))"
[ "$failed" -eq 0 ] || exit 1
echo "全部通过"
exit 0
