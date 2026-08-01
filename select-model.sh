#!/usr/bin/env bash
set -euo pipefail

# Presentation and input for choosing a model from models.json.
#
# Usage: select-model.sh <models.json> [gpu_vram_gb]
#
# Prints the menu and all prompts to stderr, then prints the selected
# model's fields to stdout as shell assignments, e.g.:
#   MODEL_REPO='unsloth/Qwen3.5-4B-GGUF'
#   MODEL_FILE='Qwen3.5-4B-Q4_K_M.gguf'
#   MODEL_NAME='Qwen3.5 4B (Q4_K_M)'
#   LLAMA_CONTEXT_SIZE='65536'
#   MODEL_MIN_VRAM_GB='8'
#
# Callers should capture stdout and eval it, e.g.:
#   eval "$(select-model.sh models.json "$GPU_VRAM_GB")"
#
# gpu_vram_gb, if given and non-empty, enables fit/too-big annotations in
# the menu and the VRAM-shortfall confirmation prompt.

MODELS_JSON="${1:-}"
GPU_VRAM_GB="${2:-}"

if [ -z "$MODELS_JSON" ]; then
    echo "Usage: $0 <models.json> [gpu_vram_gb]" >&2
    exit 1
fi

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_RESET=""
fi

if [ ! -f "$MODELS_JSON" ]; then
    echo "Model catalog not found: $MODELS_JSON" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to read $MODELS_JSON but is not installed." >&2
    echo "Install it first:  sudo apt install jq" >&2
    exit 1
fi
if ! jq -e '.models | arrays and length > 0' "$MODELS_JSON" >/dev/null 2>&1; then
    echo "$MODELS_JSON has no usable \"models\" array." >&2
    exit 1
fi

count="$(jq -r '.models | length' "$MODELS_JSON")"
default_id="$(jq -r '.default // .models[0].id' "$MODELS_JSON")"
default_idx=0

# Sort by min_vram_gb ascending so display order doesn't depend on file order.
order="$(jq -r '.models | to_entries | sort_by(.value.min_vram_gb) | map(.key) | @sh' "$MODELS_JSON" | tr -d \')"
order=($order)

# Print the menu, remembering which row is the default.
for (( pos = 0; pos < count; pos++ )); do
    i="${order[$pos]}"
    id="$(jq -r ".models[$i].id" "$MODELS_JSON")"
    name="$(jq -r ".models[$i].name" "$MODELS_JSON")"
    min_vram="$(jq -r ".models[$i].min_vram_gb" "$MODELS_JSON")"

    if [ -n "$GPU_VRAM_GB" ] && [ "$min_vram" -gt "$GPU_VRAM_GB" ]; then
        fit="${COLOR_RED}too big for your ${GPU_VRAM_GB}GB GPU${COLOR_RESET}"
    else
        fit="${COLOR_GREEN}fits${COLOR_RESET}"
    fi

    marker="  "
    if [ "$id" = "$default_id" ]; then
        marker=" *"
        default_idx=$(( pos + 1 ))
    fi

    printf '%s%2d) %2sGB VRAM  %-24s [%s]\n' \
        "$marker" "$(( pos + 1 ))" "$min_vram" "$name" "$fit" >&2
done

[ "$default_idx" -eq 0 ] && default_idx=1
printf '\n  * = default\n' >&2

# Read a choice. Without a TTY (piped/CI), take the default rather than hang.
choice=""
if [ -t 0 ]; then
    printf '\nSelect a model [1-%d] (press enter for %d): ' "$count" "$default_idx" >&2
    read -r choice || choice=""
else
    echo "No terminal available for input; using the default model." >&2
fi
[ -z "$choice" ] && choice="$default_idx"

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    echo "Invalid selection: $choice" >&2
    exit 1
fi

idx="${order[$(( choice - 1 ))]}"
MODEL_REPO="$(jq -r ".models[$idx].repo" "$MODELS_JSON")"
MODEL_FILE="$(jq -r ".models[$idx].file" "$MODELS_JSON")"
MODEL_NAME="$(jq -r ".models[$idx].name" "$MODELS_JSON")"
LLAMA_CONTEXT_SIZE="$(jq -r ".models[$idx].context_size" "$MODELS_JSON")"
MODEL_MIN_VRAM_GB="$(jq -r ".models[$idx].min_vram_gb" "$MODELS_JSON")"

printf '\nSelected: %s\n' "$MODEL_NAME" >&2

if [ -n "$GPU_VRAM_GB" ] && [ "$MODEL_MIN_VRAM_GB" -gt "$GPU_VRAM_GB" ]; then
    printf '\n%sWARNING:%s %s wants ~%sGB of VRAM, but this GPU has %sGB.\n' \
        "$COLOR_RED" "$COLOR_RESET" "$MODEL_NAME" "$MODEL_MIN_VRAM_GB" "$GPU_VRAM_GB" >&2
    printf 'It may fail to load, or spill into system RAM and run very slowly.\n' >&2

    if [ ! -t 0 ]; then
        echo "No terminal available to confirm; refusing to continue." >&2
        exit 1
    fi

    answer=""
    printf '\nUse it anyway? [y/N]: ' >&2
    read -r answer || answer=""
    case "$answer" in
        [yY]|[yY][eE][sS]) echo "Continuing with $MODEL_NAME despite the VRAM shortfall." >&2 ;;
        *) echo "Aborted." >&2; exit 1 ;;
    esac
fi

printf 'MODEL_REPO=%q\n' "$MODEL_REPO"
printf 'MODEL_FILE=%q\n' "$MODEL_FILE"
printf 'MODEL_NAME=%q\n' "$MODEL_NAME"
printf 'LLAMA_CONTEXT_SIZE=%q\n' "$LLAMA_CONTEXT_SIZE"
printf 'MODEL_MIN_VRAM_GB=%q\n' "$MODEL_MIN_VRAM_GB"
