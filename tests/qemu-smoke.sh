#!/usr/bin/env bash
# Boot the kernel smoke variants under OVMF with Limine. Exits non-zero unless
# every boot produces the expected serial markers and QEMU exit codes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIMINE_VERSION="${LIMINE_VERSION:-v12.9.4}"
LIMINE_SHA256="${LIMINE_SHA256:-847334bc4bc142de996fbd132806b89ed73ac9ab34dbc1e90cfebf1fcc68c2b1}"
LIMINE_URL="https://github.com/limine-bootloader/limine/releases/download/${LIMINE_VERSION}/limine-binary.tar.gz"

DEPS="$ROOT/deps/limine"
LIMINE_DIR="$DEPS/limine-binary"
KERNEL="$ROOT/zig-out/bin/kernel.elf"
PANIC_KERNEL="$ROOT/zig-out/bin/kernel-panic.elf"
EXCEPTION_KERNEL="$ROOT/zig-out/bin/kernel-exception.elf"
NMI_KERNEL="$ROOT/zig-out/bin/kernel-nmi.elf"
TIMER_KERNEL="$ROOT/zig-out/bin/kernel-timer.elf"
MEM_KERNEL="$ROOT/zig-out/bin/kernel-mem.elf"
IRQ_KERNEL="$ROOT/zig-out/bin/kernel-irq.elf"
BOOT_CONF="$ROOT/boot/limine.conf"
ESP="$ROOT/zig-out/esp"
ACCEL="${QEMU_ACCEL:-tcg}"

if [[ ! -f "$KERNEL" ]]; then
    echo "qemu-smoke: missing $KERNEL; run 'zig build kernel'" >&2
    exit 2
fi
if [[ ! -f "$PANIC_KERNEL" ]]; then
    echo "qemu-smoke: missing $PANIC_KERNEL; run 'zig build kernel-panic'" >&2
    exit 2
fi
if [[ ! -f "$EXCEPTION_KERNEL" ]]; then
    echo "qemu-smoke: missing $EXCEPTION_KERNEL; run 'zig build kernel-exception'" >&2
    exit 2
fi
if [[ ! -f "$NMI_KERNEL" ]]; then
    echo "qemu-smoke: missing $NMI_KERNEL; run 'zig build kernel-nmi'" >&2
    exit 2
fi
if [[ ! -f "$TIMER_KERNEL" ]]; then
    echo "qemu-smoke: missing $TIMER_KERNEL; run 'zig build kernel-timer'" >&2
    exit 2
fi
if [[ ! -f "$MEM_KERNEL" ]]; then
    echo "qemu-smoke: missing $MEM_KERNEL; run 'zig build kernel-mem'" >&2
    exit 2
fi
if [[ ! -f "$IRQ_KERNEL" ]]; then
    echo "qemu-smoke: missing $IRQ_KERNEL; run 'zig build kernel-irq'" >&2
    exit 2
fi

if [[ ! -f "$LIMINE_DIR/BOOTX64.EFI" ]]; then
    mkdir -p "$DEPS"
    TARBALL="$DEPS/limine-binary.tar.gz"
    echo "qemu-smoke: downloading Limine $LIMINE_VERSION"
    curl -fL --retry 3 -o "$TARBALL" "$LIMINE_URL"
    actual="$(sha256sum "$TARBALL" | awk '{print $1}')"
    if [[ "$actual" != "$LIMINE_SHA256" ]]; then
        echo "qemu-smoke: Limine checksum mismatch: $actual" >&2
        exit 2
    fi
    rm -rf "$LIMINE_DIR"
    # GNU tar on MSYS treats the "D:" in an absolute Windows path as a remote
    # host; extract by relative name from the download directory instead.
    (cd "$DEPS" && tar -xzf "limine-binary.tar.gz")
fi

if [[ -n "${QEMU:-}" ]]; then
    QEMU_BIN="$QEMU"
elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
    QEMU_BIN="$(command -v qemu-system-x86_64)"
elif [[ -x "/c/Program Files/qemu/qemu-system-x86_64.exe" ]]; then
    QEMU_BIN="/c/Program Files/qemu/qemu-system-x86_64.exe"
else
    echo "qemu-smoke: qemu-system-x86_64 not found; set QEMU=/path/to/qemu-system-x86_64" >&2
    exit 2
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        to_qemu_path() { cygpath -m "$1"; }
        DEFAULT_OVMF_CODE="C:/Program Files/qemu/share/edk2-x86_64-code.fd"
        DEFAULT_OVMF_VARS="C:/Program Files/qemu/share/edk2-i386-vars.fd"
        ;;
    *)
        to_qemu_path() { printf '%s\n' "$1"; }
        DEFAULT_OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
        DEFAULT_OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
        if [[ ! -f "$DEFAULT_OVMF_CODE" ]]; then
            DEFAULT_OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
            DEFAULT_OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"
        fi
        if [[ ! -f "$DEFAULT_OVMF_CODE" ]]; then
            DEFAULT_OVMF_CODE="/usr/share/ovmf/OVMF.fd"
            DEFAULT_OVMF_VARS=""
        fi
        ;;
esac

OVMF_CODE="${OVMF_CODE:-$DEFAULT_OVMF_CODE}"
OVMF_VARS="${OVMF_VARS:-$DEFAULT_OVMF_VARS}"

if [[ ! -f "$OVMF_CODE" ]]; then
    echo "qemu-smoke: OVMF code not found at $OVMF_CODE" >&2
    exit 2
fi

FW_ARGS=()
if [[ -n "$OVMF_VARS" ]]; then
    if [[ ! -f "$OVMF_VARS" ]]; then
        echo "qemu-smoke: OVMF vars not found at $OVMF_VARS" >&2
        exit 2
    fi
    VARS_COPY="$ROOT/zig-out/ovmf-vars.fd"
    cp "$OVMF_VARS" "$VARS_COPY"
    FW_ARGS=(
        -drive "if=pflash,format=raw,readonly=on,file=$(to_qemu_path "$OVMF_CODE")"
        -drive "if=pflash,format=raw,file=$(to_qemu_path "$VARS_COPY")"
    )
else
    FW_ARGS=(-bios "$(to_qemu_path "$OVMF_CODE")")
fi

stage_esp() {
    rm -rf "$ESP"
    mkdir -p "$ESP/EFI/BOOT"
    cp "$LIMINE_DIR/BOOTX64.EFI" "$ESP/EFI/BOOT/BOOTX64.EFI"
    cp "$BOOT_CONF" "$ESP/EFI/BOOT/limine.conf"
}

run_boot() {
    local kernel="$1"
    local expected_exit="$2"
    local marker="$3"
    local label="$4"
    local log="$ROOT/zig-out/serial-$label.log"

    cp "$kernel" "$ESP/kernel.elf"
    rm -f "$log"

    local code=0
    set +e
    timeout 120 "$QEMU_BIN" \
        -M q35 \
        -m 512M \
        -cpu "${QEMU_CPU:-max}" \
        -accel "$ACCEL" \
        "${FW_ARGS[@]}" \
        -drive "file=fat:rw:$(to_qemu_path "$ESP"),format=raw" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -serial "file:$(to_qemu_path "$log")" \
        -display none -monitor none -no-reboot \
        -boot order=c
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
    echo "qemu-smoke: $label OK (exit $code)"
}

stage_esp
run_boot "$KERNEL" 33 "ZigOS M1 OK" normal
run_boot "$PANIC_KERNEL" 35 "PANIC: index out of bounds" panic
run_boot "$EXCEPTION_KERNEL" 37 "EXCEPTION 3: breakpoint" exception
run_boot "$NMI_KERNEL" 39 "EXCEPTION 2: non-maskable interrupt" nmi
run_boot "$TIMER_KERNEL" 41 "TIMER OK" timer
run_boot "$MEM_KERNEL" 45 "MEM OK" mem
run_boot "$IRQ_KERNEL" 49 "IRQ OK" irq

PANIC_LOG="$ROOT/zig-out/serial-panic.log"
if ! grep -a -q "BACKTRACE:" "$PANIC_LOG" || ! grep -a -q "  #0 " "$PANIC_LOG"; then
    echo "qemu-smoke: panic serial output missing backtrace frames" >&2
    tail -n 120 "$PANIC_LOG" 2>/dev/null || true
    exit 1
fi
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
