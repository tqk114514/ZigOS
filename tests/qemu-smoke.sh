#!/usr/bin/env bash
# Boot the kernel smoke variants under OVMF with Limine. Exits non-zero unless
# every boot produces the expected serial markers and QEMU exit codes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KERNEL="$ROOT/zig-out/bin/kernel.elf"
PANIC_KERNEL="$ROOT/zig-out/bin/kernel-panic.elf"
EXCEPTION_KERNEL="$ROOT/zig-out/bin/kernel-exception.elf"
NMI_KERNEL="$ROOT/zig-out/bin/kernel-nmi.elf"
TIMER_KERNEL="$ROOT/zig-out/bin/kernel-timer.elf"
MEM_KERNEL="$ROOT/zig-out/bin/kernel-mem.elf"
IRQ_KERNEL="$ROOT/zig-out/bin/kernel-irq.elf"
SMP_KERNEL="$ROOT/zig-out/bin/kernel-smp.elf"
SCHED_KERNEL="$ROOT/zig-out/bin/kernel-sched.elf"
OBJECT_KERNEL="$ROOT/zig-out/bin/kernel-object.elf"
USER_KERNEL="$ROOT/zig-out/bin/kernel-user.elf"
BLK_KERNEL="$ROOT/zig-out/bin/kernel-blk.elf"
SHELL_KERNEL="$ROOT/zig-out/bin/kernel-shell.elf"
ACCEL="${QEMU_ACCEL:-tcg}"

check_kernel() {
    if [[ ! -f "$1" ]]; then
        echo "qemu-smoke: missing $1; run 'zig build $2'" >&2
        exit 2
    fi
}

check_kernel "$KERNEL" kernel
check_kernel "$PANIC_KERNEL" kernel-panic
check_kernel "$EXCEPTION_KERNEL" kernel-exception
check_kernel "$NMI_KERNEL" kernel-nmi
check_kernel "$TIMER_KERNEL" kernel-timer
check_kernel "$MEM_KERNEL" kernel-mem
check_kernel "$IRQ_KERNEL" kernel-irq
check_kernel "$SMP_KERNEL" kernel-smp
check_kernel "$SCHED_KERNEL" kernel-sched
check_kernel "$OBJECT_KERNEL" kernel-object
check_kernel "$USER_KERNEL" kernel-user
check_kernel "$BLK_KERNEL" kernel-blk
check_kernel "$SHELL_KERNEL" kernel-shell
check_kernel "$ROOT/zig-out/bin/shell.elf" shell

# shellcheck source=tests/qemu-env.sh
source "$ROOT/tests/qemu-env.sh"

BLK_IMAGE="$ROOT/zig-out/blk.img"
cp "$ROOT/zig-out/initramfs.img" "$BLK_IMAGE"
truncate -s 4096 "$BLK_IMAGE"

stage_esp

run_boot() {
    local kernel="$1"
    local expected_exit="$2"
    local marker="$3"
    local label="$4"
    local smp="${5:-1}"
    local extra="${6:-}"
    local log="$ROOT/zig-out/serial-$label.log"
    if [[ "$smp" != "1" ]]; then
        log="$ROOT/zig-out/serial-$label-smp$smp.log"
    fi

    cp "$kernel" "$ESP/kernel.elf"
    rm -f "$log"

    local code=0
    set +e
    timeout 120 "$QEMU_BIN" \
        -M q35 \
        -m 512M \
        -smp "$smp" \
        -cpu "${QEMU_CPU:-max}" \
        -accel "$ACCEL" \
        "${FW_ARGS[@]}" \
        -drive "file=fat:rw:$(to_qemu_path "$ESP"),format=raw" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -serial "file:$(to_qemu_path "$log")" \
        -display none -monitor none -no-reboot \
        -boot order=c         ${extra}
    code=$?
    set -e

    if [[ "$code" -ne "$expected_exit" ]]; then
        echo "qemu-smoke: $label exited $code, expected $expected_exit" >&2
        tail -n 120 "$log" 2>/dev/null || true
        exit 1
    fi
    if ! grep -a -q "$marker" "$log"; then
        echo "qemu-smoke: $label serial output missing '$marker'" >&2
        tail -n 120 "$log" 2>/dev/null || true
        exit 1
    fi
    echo "qemu-smoke: $label smp=$smp OK (exit $code)"
}

run_shell_boot() {
    local smp="$1"
    local log="$ROOT/zig-out/serial-shell.log"
    if [[ "$smp" != "1" ]]; then
        log="$ROOT/zig-out/serial-shell-smp$smp.log"
    fi

    cp "$SHELL_KERNEL" "$ESP/kernel.elf"
    rm -f "$log"

    # COM1 input is fed line by line once each prompt is visible, one byte at
    # a time; bursts overrun the UART receive FIFO.
    local code=0
    set +e
    (
        local -a commands=("cat /etc/motd" "cat /hello.txt" "cat /missing" "sysfuzz" "exit")
        local index=0
        while [[ "$index" -lt "${#commands[@]}" ]]; do
            local target=$((index + 1))
            local tries=0
            while [[ "$tries" -lt 600 ]]; do
                local seen
                seen=$(grep -a -c "shell> " "$log" 2>/dev/null || true)
                [[ "${seen:-0}" -ge "$target" ]] && break
                sleep 0.1
                tries=$((tries + 1))
            done
            local text="${commands[$index]}"
            local char=0
            while [[ "$char" -lt "${#text}" ]]; do
                printf '%s' "${text:$char:1}"
                sleep 0.03
                char=$((char + 1))
            done
            sleep 0.1
            printf '\n'
            sleep 0.2
            index=$((index + 1))
        done
    ) | timeout 120 "$QEMU_BIN" \
        -M q35 \
        -m 512M \
        -smp "$smp" \
        -cpu "${QEMU_CPU:-max}" \
        -accel "$ACCEL" \
        "${FW_ARGS[@]}" \
        -drive "file=fat:rw:$(to_qemu_path "$ESP"),format=raw" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -serial stdio \
        -display none -monitor none -no-reboot \
        -boot order=c > "$log" 2>&1
    code=$?
    set -e

    if [[ "$code" -ne 77 ]]; then
        echo "qemu-smoke: shell exited $code, expected 77" >&2
        tail -n 120 "$log" 2>/dev/null || true
        exit 1
    fi
    if ! grep -a -q "SHELL OK" "$log"; then
        echo "qemu-smoke: shell serial output missing 'SHELL OK'" >&2
        tail -n 120 "$log" 2>/dev/null || true
        exit 1
    fi
    echo "qemu-smoke: shell smp=$smp OK (exit $code)"
}

for smp in 1 4; do
    run_boot "$KERNEL" 33 "ZigOS M1 OK" normal "$smp"
    run_boot "$PANIC_KERNEL" 35 "PANIC: index out of bounds" panic "$smp"
    run_boot "$EXCEPTION_KERNEL" 37 "EXCEPTION 3: breakpoint" exception "$smp"
    run_boot "$NMI_KERNEL" 39 "EXCEPTION 2: non-maskable interrupt" nmi "$smp"
    run_boot "$TIMER_KERNEL" 41 "TIMER OK" timer "$smp"
    run_boot "$MEM_KERNEL" 45 "MEM OK" mem "$smp"
    run_boot "$IRQ_KERNEL" 49 "IRQ OK" irq "$smp"
    run_boot "$SMP_KERNEL" 57 "SMP OK" smp "$smp"
    run_boot "$SCHED_KERNEL" 61 "SCHED OK" sched "$smp"
    run_boot "$OBJECT_KERNEL" 65 "OBJECT OK" object "$smp"
    run_boot "$USER_KERNEL" 69 "USER OK" user "$smp"
    run_boot "$BLK_KERNEL" 73 "BLK OK" blk "$smp" "-drive file=$(to_qemu_path "$BLK_IMAGE"),if=virtio,format=raw"
    run_shell_boot "$smp"
done

PANIC_LOG="$ROOT/zig-out/serial-panic.log"
if ! grep -a -q "BACKTRACE:" "$PANIC_LOG" || ! grep -a -q "  #0 " "$PANIC_LOG"; then
    echo "qemu-smoke: panic serial output missing backtrace frames" >&2
    tail -n 120 "$PANIC_LOG" 2>/dev/null || true
    exit 1
fi
if ! grep -a -q "INITRAMFS: .* bytes  ok" "$ROOT/zig-out/serial-normal.log"; then
    echo "qemu-smoke: initramfs module missing or invalid" >&2
    tail -n 120 "$ROOT/zig-out/serial-normal.log" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: initramfs module OK"

echo "qemu-smoke: backtrace OK"

EXCEPTION_LOG="$ROOT/zig-out/serial-exception.log"
if ! grep -a -q "rip:" "$EXCEPTION_LOG" || ! grep -a -q "cs: 0008" "$EXCEPTION_LOG"; then
    echo "qemu-smoke: exception serial output missing CPU frame or new GDT CS" >&2
    tail -n 120 "$EXCEPTION_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: exception frame OK"

NMI_LOG="$ROOT/zig-out/serial-nmi.log"
if ! grep -a -q "rip:" "$NMI_LOG" ||
   ! grep -a -q "cs: 0008" "$NMI_LOG" ||
   ! grep -a -q "ist: ok" "$NMI_LOG"; then
    echo "qemu-smoke: NMI serial output missing CPU frame, new GDT CS, or IST stack" >&2
    tail -n 120 "$NMI_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: NMI IST OK"

IRQ_LOG="$ROOT/zig-out/serial-irq.log"
if ! grep -a -q "EXT: ioapic base" "$IRQ_LOG" ||
   ! grep -a -q "EXT: gsi 8 -> vector 48" "$IRQ_LOG"; then
    echo "qemu-smoke: irq serial output missing the IOAPIC setup evidence" >&2
    tail -n 120 "$IRQ_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: IOAPIC route OK"

MEM_LOG="$ROOT/zig-out/serial-mem.log"
if ! grep -a -q "MEM: heap pressure" "$MEM_LOG" ||
   ! grep -a -q "MEM: frames exhausted" "$MEM_LOG"; then
    echo "qemu-smoke: mem serial output missing the exhaustion evidence" >&2
    tail -n 120 "$MEM_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: memory pressure OK"

SMP_LOG="$ROOT/zig-out/serial-smp-smp4.log"
if ! grep -a -q "SMP: cpu 3 apic" "$SMP_LOG" ||
   ! grep -a -q "SMP: cpus 4 online 4" "$SMP_LOG" ||
   ! grep -a -q "SMP: alloc stress ok" "$SMP_LOG"; then
    echo "qemu-smoke: smp serial output missing the per-CPU or stress evidence" >&2
    tail -n 120 "$SMP_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: SMP CPUs OK"

SCHED_LOG="$ROOT/zig-out/serial-sched-smp4.log"
if ! grep -a -q "SCHED: cpu 3 switches" "$SCHED_LOG" ||
   ! grep -a -q "SCHED: thread " "$SCHED_LOG" ||
   ! grep -a -q "SCHED: guard pages ok" "$SCHED_LOG" ||
   ! grep -a -q "SCHED: sleep ok" "$SCHED_LOG" ||
   ! grep -a -q "SCHED: wake ok" "$SCHED_LOG" ||
   ! grep -a -q "TLB: shootdown ok" "$SCHED_LOG"; then
    echo "qemu-smoke: sched serial output missing the preemption evidence" >&2
    tail -n 120 "$SCHED_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: scheduler preemption OK"

USER_LOG="$ROOT/zig-out/serial-user-smp4.log"
if ! grep -a -q "USER: ring3 ok" "$USER_LOG" ||
   ! grep -a -q "USER: spin ok" "$USER_LOG" ||
   ! grep -a -q "USER: reclaim ok" "$USER_LOG" ||
   ! grep -a -q "USER: preempt ticks" "$USER_LOG" ||
   ! grep -a -q "USER: space B remapped ok" "$USER_LOG"; then
    echo "qemu-smoke: user serial output missing the ring3/preemption evidence" >&2
    tail -n 120 "$USER_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: user ring3 and preemption OK"

if ! grep -a -q "BLK: pci 1af4:" "$ROOT/zig-out/serial-blk-smp4.log" ||
   ! grep -a -q "BLK: read sector 0 ok" "$ROOT/zig-out/serial-blk-smp4.log"; then
    echo "qemu-smoke: blk serial output missing the discovery or read evidence" >&2
    tail -n 120 "$ROOT/zig-out/serial-blk-smp4.log" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: virtio-blk discovery and read OK"

SHELL_LOG="$ROOT/zig-out/serial-shell-smp4.log"
if ! grep -a -q "ZigOS shell (M3)" "$SHELL_LOG" ||
   ! grep -a -q "ZigOS M3" "$SHELL_LOG" ||
   ! grep -a -q "hello from the packaged initramfs" "$SHELL_LOG" ||
   ! grep -a -q "not found" "$SHELL_LOG" ||
   ! grep -a -q "sysfuzz ok" "$SHELL_LOG" ||
   ! grep -a -q "PROCESS: isolation ok" "$SHELL_LOG" ||
   ! grep -a -q "SHELL: space reclaimed" "$SHELL_LOG"; then
    echo "qemu-smoke: shell serial output missing prompt, file contents, sysfuzz, isolation, or reclamation" >&2
    tail -n 120 "$SHELL_LOG" 2>/dev/null || true
    exit 1
fi
echo "qemu-smoke: user shell, syscall fuzz, process isolation, and reclamation OK"