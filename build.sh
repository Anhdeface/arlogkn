#!/usr/bin/env bash
# file: build.sh
# Build script for sys-diag

BUILDER_VERSION="0.0.1"
ARLOGKN_VERSION="1.1"

set -euo pipefail
cd "$(dirname "$0")"

TARGET="universal"
HW_MODE="basic"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --hwv2)
            HW_MODE="v2"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

OUT_DIR="build/output"
OUT_FILE="${OUT_DIR}/sys-diag.sh"
mkdir -p "$OUT_DIR"
rm -f "$OUT_FILE"

echo "[INFO] Building target: $TARGET"

# 1. Header and globals
cat src/core/00-header.sh > "$OUT_FILE"

# Inject COMPILED_TARGET and VERSION
echo "" >> "$OUT_FILE"
echo "# --- INJECTED BY BUILD SYSTEM ---" >> "$OUT_FILE"
echo "declare -g _COMPILED_TARGET=\"$TARGET\"" >> "$OUT_FILE"
echo "readonly VERSION=\"$ARLOGKN_VERSION\"" >> "$OUT_FILE"
echo "# --------------------------------" >> "$OUT_FILE"
echo "" >> "$OUT_FILE"

# 2. Rest of Core (excluding header and main)
# Use find and sort to ensure strict numerical ordering
while IFS= read -r f; do
    if [[ "$(basename "$f")" != "00-header.sh" ]]; then
        cat "$f" >> "$OUT_FILE"
    fi
done < <(find src/core -maxdepth 1 -name '0*.sh' | sort -n)

# 3. Plugins
if [[ "$TARGET" != "universal" ]]; then
    PLUGIN_DIR="src/plugins/${TARGET}"
    if [[ -d "$PLUGIN_DIR" ]]; then
        while IFS= read -r f; do
            [[ -e "$f" ]] || continue
            cat "$f" >> "$OUT_FILE"
        done < <(find "$PLUGIN_DIR" -maxdepth 1 -name 'plugin-*.sh' | sort)
    else
        echo "[WARN] Plugin directory $PLUGIN_DIR not found. Building without target plugins."
    fi
fi

# 3.5. Hardware V2 Plugin 
if [[ "$HW_MODE" == "v2" ]]; then
    echo "[INFO] Including HWv2 Advanced Module"
    HW_PLUGIN_DIR="src/plugins/hwv2"
    if [[ -d "$HW_PLUGIN_DIR" ]]; then
        while IFS= read -r f; do
            [[ -e "$f" ]] || continue
            cat "$f" >> "$OUT_FILE"
        done < <(find "$HW_PLUGIN_DIR" -maxdepth 1 -name 'plugin-*.sh' | sort)
    else
        echo "[WARN] HWv2 plugin directory $HW_PLUGIN_DIR not found."
    fi
fi

# 4. Main
cat src/core/99-main.sh >> "$OUT_FILE"

chmod +x "$OUT_FILE"
echo "[SUCCESS] Build complete: $OUT_FILE"
