#!/usr/bin/env bash
# Run every self-checking testbench for the 32-lane design in Icarus Verilog.
#   bash run_tests.sh          # everything; board-top test with 4 pipeline stages (~2 min)
#   bash run_tests.sh full     # board-top test with the board's 32 stages (~8 min)
#   bash run_tests.sh quick    # skip the 640x480 board-top test
# Needs iverilog (brew install icarus-verilog). Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
R=rtl
CORE="$R/ca_video_core_wide.v $R/ca_double_buffer_wide.v $R/ca_update_engine_wide.v $R/ca_pipeline_engine.v $R/ca_stage.v $R/vga_timing_ce.v $R/uart_tx.v"
fail=0

run() {   # name, pass-pattern, files... (extra iverilog flags via $IVFLAGS)
    local name=$1 pat=$2; shift 2
    printf '%-32s ' "$name"
    if ! iverilog -g2012 ${IVFLAGS:-} -o "$OUT/$name" "$@" 2>"$OUT/$name.err"; then
        echo "COMPILE ERROR"; cat "$OUT/$name.err"; fail=1; return
    fi
    if vvp "$OUT/$name" >"$OUT/$name.log" 2>&1 && grep -q "$pat" "$OUT/$name.log" \
       && ! grep -q "FAIL" "$OUT/$name.log"; then
        echo "PASS"
    else
        echo "FAIL (log below)"; tail -20 "$OUT/$name.log"; fail=1
    fi
}

run tb_ca_update_engine_wide "ALL CONFIGURATIONS PASSED" tb/tb_ca_update_engine_wide.v $R/ca_update_engine_wide.v
run tb_ca_video_core_wide    "ALL CONFIGURATIONS PASSED" tb/tb_ca_video_core_wide.v $CORE
run tb_ca_pipeline_engine    "ALL CONFIGURATIONS PASSED" tb/tb_ca_pipeline_engine.v $R/ca_pipeline_engine.v $R/ca_stage.v
run tb_gen_cycle_display     "ALL TESTS PASSED"          tb/tb_gen_cycle_display.v $R/gen_cycle_display.v
if [ "${1:-}" != "quick" ]; then
    K=4; [ "${1:-}" = "full" ] && K=32
    IVFLAGS="-Ptb_nexys_a7_top_wide_perf.TB_STAGES=$K" \
    run tb_nexys_a7_top_wide_perf "ALL TESTS PASSED" tb/tb_nexys_a7_top_wide_perf.v \
        $R/nexys_a7_top_wide.v $R/clk_gen.v $R/gen_cycle_display.v $CORE
fi

[ $fail -eq 0 ] && echo "ALL TESTBENCHES PASSED" || echo "SOME TESTBENCHES FAILED"
exit $fail
