#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
MODEL_REPO="bartowski/Qwen_Qwen3.5-4B-GGUF"
MODEL_FILE="Qwen_Qwen3.5-4B-Q6_K_L.gguf"
QWEN_SETTINGS="$HOME/.qwen/settings.json"
QWEN_STANDALONE_INSTALLER="https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh"
LLAMA_PORT=8080
LLAMA_CONTEXT_SIZE=65536

DRY_RUN=1
MODEL_PATH=""
LLAMA_SERVER_BIN=""

print_usage() {
    cat <<EOF
Usage: $0 [--install]

With no arguments, this script does a DRY RUN: it prints what already exists
on this machine and what it would install or change, but makes no changes.

Pass --install to actually perform the installation.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --install|--apply|-y) DRY_RUN=0 ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; print_usage; exit 1 ;;
    esac
done

log() { printf '\n== %s ==\n' "$1"; }
have() { printf '  [ok]    %s\n' "$1"; }
would() { printf '  [would] %s\n' "$1"; }

check_gpu() {
    log "Checking for NVIDIA GPU"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "nvidia-smi not found. An NVIDIA GPU with drivers installed is required." >&2
        exit 1
    fi
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | sed 's/^/  /'
}

ensure_apt_packages() {
    log "Build dependencies"
    local pkgs=(cmake build-essential python3 python3-pip python3-venv jq)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        have "All build dependencies already installed (${pkgs[*]})"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        would "Install missing packages via apt: ${missing[*]}"
    else
        echo "Installing missing packages: ${missing[*]}"
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi
}

ensure_cuda_compiler() {
    if command -v nvcc >/dev/null 2>&1; then
        have "CUDA compiler found: nvcc $(nvcc --version | grep -oP 'release \K[0-9.]+')"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        would "Install CUDA toolkit via apt (nvidia-cuda-toolkit) to get the nvcc compiler needed to build llama.cpp with GPU support"
        return
    fi

    echo "Installing CUDA toolkit (nvcc) via apt"
    sudo apt-get update
    sudo apt-get install -y nvidia-cuda-toolkit
    command -v nvcc >/dev/null 2>&1 || { echo "nvcc still not found after installing nvidia-cuda-toolkit" >&2; exit 1; }
}

ensure_llama_cpp() {
    log "llama.cpp"

    if command -v llama-server >/dev/null 2>&1; then
        LLAMA_SERVER_BIN="$(command -v llama-server)"
        have "llama-server already on PATH: $LLAMA_SERVER_BIN"
        return
    fi

    ensure_cuda_compiler

    LLAMA_SERVER_BIN="$LLAMA_DIR/build/bin/llama-server"

    if [ ! -d "$LLAMA_DIR/.git" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            would "Clone and build llama.cpp with CUDA support into $LLAMA_DIR (~5-15 minutes)"
            return
        fi
        echo "Cloning llama.cpp to $LLAMA_DIR"
        git clone "$LLAMA_REPO" "$LLAMA_DIR"
    else
        have "Existing checkout found at $LLAMA_DIR"
    fi

    echo "Checking for updates..."
    git -C "$LLAMA_DIR" fetch --quiet

    local current_commit remote_commit stamp_file stamped_commit=""
    current_commit="$(git -C "$LLAMA_DIR" rev-parse HEAD)"
    remote_commit="$(git -C "$LLAMA_DIR" rev-parse '@{u}' 2>/dev/null || echo "$current_commit")"
    stamp_file="$LLAMA_DIR/build/.installed_commit"
    [ -f "$stamp_file" ] && stamped_commit="$(cat "$stamp_file")"

    if [ "$current_commit" != "$remote_commit" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            would "Update local checkout to latest llama.cpp commit"
        else
            echo "Updating to latest llama.cpp"
            git -C "$LLAMA_DIR" merge --ff-only "@{u}"
        fi
    fi

    if [ ! -x "$LLAMA_DIR/build/bin/llama-server" ] || [ "$current_commit" != "$stamped_commit" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            would "Build llama.cpp with CUDA support (cmake + build, ~5-15 minutes)"
        else
            echo "Building llama.cpp with CUDA support (this may take a while)"
            cmake -B "$LLAMA_DIR/build" -S "$LLAMA_DIR" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
            cmake --build "$LLAMA_DIR/build" --config Release -j"$(nproc)"
            git -C "$LLAMA_DIR" rev-parse HEAD > "$stamp_file"
        fi
    else
        have "Existing build is up to date"
    fi
}

ensure_model() {
    log "Model: $MODEL_REPO / $MODEL_FILE"

    MODEL_PATH="$(find "$HOME/.cache/huggingface/hub" \( -type f -o -type l \) -name "$MODEL_FILE" 2>/dev/null | head -n1)"
    if [ -n "$MODEL_PATH" ]; then
        have "Model already downloaded: $MODEL_PATH"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        would "Download model $MODEL_REPO/$MODEL_FILE (~4GB) via huggingface-cli"
        return
    fi

    local hf_cmd=""
    if command -v hf >/dev/null 2>&1; then
        hf_cmd="hf"
    elif command -v huggingface-cli >/dev/null 2>&1; then
        hf_cmd="huggingface-cli"
    else
        echo "Installing huggingface_hub CLI"
        pip install --user --upgrade "huggingface_hub[cli]"
        hash -r
        hf_cmd="hf"
        command -v hf >/dev/null 2>&1 || hf_cmd="huggingface-cli"
    fi

    if [ "$hf_cmd" = "hf" ]; then
        hf download "$MODEL_REPO" "$MODEL_FILE"
    else
        huggingface-cli download "$MODEL_REPO" "$MODEL_FILE"
    fi

    MODEL_PATH="$(find "$HOME/.cache/huggingface/hub" \( -type f -o -type l \) -name "$MODEL_FILE" 2>/dev/null | head -n1)"
    if [ -z "$MODEL_PATH" ]; then
        echo "Could not locate downloaded model file under ~/.cache/huggingface/hub" >&2
        exit 1
    fi
    echo "Model at: $MODEL_PATH"
}

ensure_qwen_code() {
    log "Qwen Code CLI"
    if command -v qwen >/dev/null 2>&1; then
        have "qwen already installed: $(command -v qwen)"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        would "Install Qwen Code CLI via the official standalone installer"
        return
    fi

    echo "Running official Qwen Code standalone installer"
    curl -fsSL "$QWEN_STANDALONE_INSTALLER" | bash
    hash -r
}

render_qwen_settings() {
    local base_url="http://127.0.0.1:${LLAMA_PORT}/v1"
    local default_env_key="LOCALQWEN_API_KEY"
    jq \
        --arg id "$MODEL_FILE" \
        --arg base_url "$base_url" \
        --arg default_env_key "$default_env_key" \
        '
        (.modelProviders.openai // []) as $arr
        | (($arr | map(select(.id == $id)) | .[0]) // null) as $existing
        | ($existing.envKey // $default_env_key) as $use_key
        | (($existing // {}) + {id: $id, name: $id, baseUrl: $base_url, envKey: $use_key}) as $entry
        | .modelProviders.openai = (
            if $existing == null then $arr + [$entry]
            else ($arr | map(if .id == $id then $entry else . end))
            end
          )
        | .env = ((.env // {}) + {($use_key): (.env[$use_key] // "dummy")})
        | .security = (.security // {})
        | .security.auth = (.security.auth // {})
        | .security.auth.selectedType = (.security.auth.selectedType // "openai")
        | .model = (if (.model.name // null) == null then {name: $id, baseUrl: $base_url} else .model end)
        ' "$1"
}

configure_qwen_settings() {
    log "Qwen Code configuration"

    if ! command -v jq >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            would "Update $QWEN_SETTINGS to point at the local server (exact diff needs jq, installed in the real run)"
            return
        fi
    fi

    local existing tmp_file
    tmp_file="$(mktemp)"
    if [ -f "$QWEN_SETTINGS" ]; then
        existing="$QWEN_SETTINGS"
    else
        existing="$(mktemp)"
        echo '{}' > "$existing"
    fi

    render_qwen_settings "$existing" > "$tmp_file"

    if [ -f "$QWEN_SETTINGS" ] && diff -q <(jq -S . "$QWEN_SETTINGS") <(jq -S . "$tmp_file") >/dev/null 2>&1; then
        have "$QWEN_SETTINGS already configured for the local server"
        rm -f "$tmp_file"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        would "Update $QWEN_SETTINGS to add/point a local model provider at http://127.0.0.1:${LLAMA_PORT}/v1"
        rm -f "$tmp_file"
    else
        mkdir -p "$(dirname "$QWEN_SETTINGS")"
        mv "$tmp_file" "$QWEN_SETTINGS"
        echo "Updated $QWEN_SETTINGS"
    fi
}

render_launch_script() {
    cat <<EOF
#!/bin/bash
set -e

MODEL="$MODEL_PATH"
PORT=$LLAMA_PORT
CONTEXT_SIZE=$LLAMA_CONTEXT_SIZE
GPU_LAYERS=999
SLOTS=1

"$LLAMA_SERVER_BIN" \\
  -m "\$MODEL" \\
  --port "\$PORT" \\
  -c "\$CONTEXT_SIZE" \\
  -ngl "\$GPU_LAYERS" \\
  --parallel "\$SLOTS"
EOF
}

write_launch_script() {
    log "Launch script"
    local launch_path="$LLAMA_DIR/launch.sh"

    if [ -f "$launch_path" ] && diff -q <(render_launch_script) "$launch_path" >/dev/null 2>&1; then
        have "Launch script already up to date: $launch_path"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        would "Write launch script to $launch_path"
        return
    fi

    render_launch_script > "$launch_path"
    chmod +x "$launch_path"
    echo "Launch script at: $launch_path"
}

main() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY RUN - checking your system, no changes will be made."
    fi

    check_gpu
    ensure_apt_packages
    ensure_llama_cpp
    ensure_model
    ensure_qwen_code
    configure_qwen_settings
    write_launch_script

    if [ "$DRY_RUN" -eq 1 ]; then
        log "This was a dry run"
        echo "Nothing was installed or changed."
        echo "To perform the actual installation, run:"
        echo ""
        echo "    $0 --install"
        echo ""
    else
        log "Done"
        echo "Start the server with: $LLAMA_DIR/launch.sh"
        echo "Then run: qwen"
    fi
}

main "$@"
