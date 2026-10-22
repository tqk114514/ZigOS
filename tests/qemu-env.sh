#!/usr/bin/env bash
# Shared QEMU/OVMF/Limine setup for the kernel test harnesses. Source it after
# defining ROOT and cd-ing to the repository root. Provides: QEMU_BIN, FW_ARGS,
# ESP, LIMINE_DIR, BOOT_CONF, to_qemu_path, and stage_esp.

LIMINE_VERSION="${LIMINE_VERSION:-v12.9.4}"
LIMINE_SHA256="${LIMINE_SHA256:-847334bc4bc142de996fbd132806b89ed73ac9ab34dbc1e90cfebf1fcc68c2b1}"
LIMINE_URL="https://github.com/limine-bootloader/limine/releases/download/${LIMINE_VERSION}/limine-binary.tar.gz"

DEPS="$ROOT/deps/limine"
LIMINE_DIR="$DEPS/limine-binary"
BOOT_CONF="$ROOT/boot/limine.conf"
ESP="$ROOT/zig-out/esp"

if [[ ! -f "$LIMINE_DIR/BOOTX64.EFI" ]]; then
    mkdir -p "$DEPS"
    TARBALL="$DEPS/limine-binary.tar.gz"
    echo "qemu-env: downloading Limine $LIMINE_VERSION"
    curl -fL --retry 3 -o "$TARBALL" "$LIMINE_URL"
    actual="$(sha256sum "$TARBALL" | awk '{print $1}')"
    if [[ "$actual" != "$LIMINE_SHA256" ]]; then
        echo "qemu-env: Limine checksum mismatch: $actual" >&2
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
    echo "qemu-env: qemu-system-x86_64 not found; set QEMU=/path/to/qemu-system-x86_64" >&2
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
    echo "qemu-env: OVMF code not found at $OVMF_CODE" >&2
    exit 2
fi

FW_ARGS=()
if [[ -n "$OVMF_VARS" ]]; then
    if [[ ! -f "$OVMF_VARS" ]]; then
        echo "qemu-env: OVMF vars not found at $OVMF_VARS" >&2
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