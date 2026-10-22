#!/usr/bin/env bash
# Boot kernel-bench under QEMU's icount mode and compare the measured cycle
# counts against tests/bench-baseline.txt (5% regression threshold). The
# committed baseline belongs to the default ReleaseSafe build; refresh it
# deliberately with BENCH_UPDATE=1 in its own commit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BENCH_KERNEL="$ROOT/zig-out/bin/kernel-bench.elf"
BASELINE="${BENCH_BASELINE:-$ROOT/tests/bench-baseline.txt}"
LOG="$ROOT/zig-out/serial-bench.log"

if [[ ! -f "$BENCH_KERNEL" ]]; then
    echo "qemu-bench: missing $BENCH_KERNEL; run 'zig build kernel-bench'" >&2
    exit 2
fi

# shellcheck source=tests/qemu-env.sh
source "$ROOT/tests/qemu-env.sh"

stage_esp
cp "$BENCH_KERNEL" "$ESP/kernel.elf"
rm -f "$LOG"

# icount makes the virtual clock (and the guest TSC) advance with executed
# instructions, so the numbers are deterministic across runs; TCG is required.
code=0
set +e
timeout 180 "$QEMU_BIN" \
    -M q35 \
    -m 512M \
    -cpu max \
    -accel tcg \
    -icount shift=7,sleep=off \
    "${FW_ARGS[@]}" \
    -drive "file=fat:rw:$(to_qemu_path "$ESP"),format=raw" \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial "file:$(to_qemu_path "$LOG")" \
    -display none -monitor none -no-reboot \
    -boot order=c
code=$?
set -e

if [[ "$code" -ne 53 ]]; then
    echo "qemu-bench: kernel-bench exited $code, expected 53" >&2
    tail -n 120 "$LOG" 2>/dev/null || true
    exit 1
fi

if ! grep -a -q "^BENCH " "$LOG"; then
    echo "qemu-bench: no BENCH lines in the serial output" >&2
    tail -n 120 "$LOG" 2>/dev/null || true
    exit 1
fi

if [[ "${BENCH_UPDATE:-}" == "1" ]]; then
    {
        echo "# Benchmark baseline for tests/qemu-bench.sh (ReleaseSafe, TCG, -icount shift=7,sleep=off)."
        echo "# Values are guest TSC cycles per operation; refresh deliberately in its own commit."
        echo "# recorded with: $("$QEMU_BIN" --version | head -n 1)"
        awk '{ gsub(/\r/, "") } /^BENCH / { printf "%s %.3f\n", $2, $3 / $4 }' "$LOG"
    } > "$BASELINE"
    echo "qemu-bench: baseline refreshed at $BASELINE"
    exit 0
fi

awk -v logfile="$LOG" -v baseline="$BASELINE" '
    BEGIN {
        while ((getline line < baseline) > 0) {
            sub(/#.*/, "", line)
            gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == "") continue
            split(line, f, /[ \t]+/)
            base[f[1]] = f[2] + 0
            order[++count] = f[1]
        }
        close(baseline)

        cmd = "grep -a \"^BENCH \" \"" logfile "\""
        while ((cmd | getline line) > 0) {
            gsub(/\r/, "", line)
            split(line, f, /[ \t]+/) # BENCH, name, cycles, ops
            cycles = f[3] + 0
            ops = f[4] + 0
            if (ops <= 0) {
                printf "qemu-bench: %s reported zero ops\n", f[2]
                bad = 1
                continue
            }
            measured[f[2]] = cycles / ops
            seen[f[2]] = 1
        }
        close(cmd)

        for (i = 1; i <= count; i++) {
            name = order[i]
            if (!(name in seen)) {
                printf "qemu-bench: missing measurement for %s\n", name
                bad = 1
                continue
            }
            cur = measured[name]
            ref = base[name]
            printf "%-13s %11.3f cycles/op (baseline %11.3f, %+.2f%%)\n", name, cur, ref, (cur - ref) * 100.0 / ref
            if (cur > ref * 1.05) {
                printf "qemu-bench: %s regressed beyond the 5%% threshold; if QEMU changed, refresh the baseline deliberately\n", name
                bad = 1
            } else if (cur < ref * 0.95) {
                printf "qemu-bench: note: %s improved by more than 5%%; refresh the baseline deliberately\n", name
            }
        }
        for (name in seen) {
            if (!(name in base)) {
                printf "qemu-bench: %s is not in the baseline; add it deliberately\n", name
                bad = 1
            }
        }
        exit bad
    }
' || {
    echo "qemu-bench: baseline comparison failed" >&2
    exit 1
}

echo "qemu-bench: OK"