# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Implemented as two scripts: `install.sh`, the main bash installer, and `select-model.sh`, which it
shells out to for the model-selection menu. No build system, tests, or dependencies beyond what they
shell out to (apt, git, cmake, jq, hf, curl, node/npx).

## Purpose

An idempotent, turnkey installation tool that prepares a laptop to run a small local LLM stack. Target
hardware assumption: an NVIDIA GPU with ~8GB VRAM (requires `nvidia-smi`; the script exits if not found).

`install.sh` sets up:
1. **Model**: chosen at runtime from the `models.json` catalog (see below), downloaded via the
   `hf`/`huggingface-cli` tool into the standard `~/.cache/huggingface/hub` cache.
2. **llama.cpp**: cloned to `~/llama.cpp` (override with `LLAMA_DIR`) and built from source with
   `-DGGML_CUDA=ON`. If `llama-server` is already on `PATH`, the build (and the `nvcc` check below) is
   skipped entirely and that binary is used instead. Otherwise, before building, `ensure_cuda_compiler`
   checks for `nvcc` on `PATH` and installs it via `apt` (`nvidia-cuda-toolkit`) if missing — plain
   `build-essential` only provides gcc/g++, which cannot compile the CUDA kernels.
3. **Qwen Code CLI**: installed via the official standalone installer script (curl | bash) if `qwen` is
   not already on `PATH`.

Before any of the above, `ensure_node` checks for `npx` on `PATH` and installs it via `apt`
(`nodejs npm`) if missing — needed both to run the MCP servers below and because the Qwen Code
standalone installer itself expects Node available.

It also configures `~/.qwen/settings.json` (via `jq`, in `render_qwen_settings`) to add/update an
`openai`-compatible model provider pointing at llama-server, and to add/update two MCP servers under
`mcpServers` — `sequentialthinking` (`@modelcontextprotocol/server-sequential-thinking`) and `memory`
(`@modelcontextprotocol/server-memory`), both run via `npx -y` so no separate install step is needed.
Both merges are additive (`(.mcpServers // {}) + {...}`), so any other MCP servers the user has
configured by hand are preserved. It also writes a `launch.sh` into this repo's own directory
(`SCRIPT_DIR`, i.e. wherever `install.sh` lives, not `LLAMA_DIR`) that starts `llama-server` with
`-ngl 999` (full GPU offload) and a 65536-token context size. `launch.sh` runs the server in the
background, polls `/health` until it responds 200, then execs `qwen --model "$MODEL_FILE"` in the same
terminal — the `--model` value matches the `id`/`name` that `render_qwen_settings` gave this model's
entry in `~/.qwen/settings.json`, so Qwen Code actually talks to the model llama-server just loaded
rather than whatever provider happens to be the settings-file default. This means a beginner only has to
run one command in one terminal; exiting `qwen` (or closing the terminal) kills the server via an `EXIT`
trap. `launch.sh` is generated, not checked in — it's gitignored.

`launch.sh` binds llama-server to `--host 0.0.0.0` (all interfaces), not just loopback, so the API is
reachable from other devices on the same LAN — e.g. a phone or laptop running Qwen Code pointed at this
machine. The Qwen settings provider URL is set to the machine's detected LAN IP (`detect_lan_ip`, via
`ip route get` falling back to `hostname -I`) rather than `127.0.0.1`, for the same reason. llama-server
itself has no auth and permissive CORS by default (it prints its own warning about this at startup) —
combined with the `0.0.0.0` bind, the API is unauthenticated and reachable by anything on the LAN. That's
an intentional tradeoff for a trusted home network, not an oversight; don't quietly narrow it back to
loopback-only without checking whether LAN reachability is still wanted.

## Model catalog (`models.json`)

`models.json` is checked in and is the single source of truth for which models can be installed. Each
entry carries `id`, `name`, `repo`, `file`, `context_size`, `min_vram_gb`, `download_size_gb`, and a
one-line `description`; a top-level `default` names the `id` pre-selected in the menu.

Menu presentation and input live in `select-model.sh`, a standalone script that `install.sh`'s
`select_model` (called after `ensure_apt_packages`, because it needs `jq`) invokes and captures via
`eval "$(select-model.sh "$MODELS_JSON" "$GPU_VRAM_GB")"`. `select-model.sh` prints the catalog as a
numbered menu to stderr, marking each entry as fitting or too big for the passed-in GPU VRAM figure, and
reads a choice from stdin. Pressing `[enter]` takes the `default`; with no TTY the default is taken
silently so piped/CI runs still work. On completion it prints the selected model's fields to stdout as
`KEY='value'` shell assignments (`MODEL_REPO`, `MODEL_FILE`, `MODEL_NAME`, `LLAMA_CONTEXT_SIZE`,
`MODEL_MIN_VRAM_GB`) — this stdout/stderr split is what lets `install.sh` `eval` just the assignments
while the menu and prompts still reach the terminal. `check_gpu` (in `install.sh`) populates
`GPU_VRAM_GB` from the largest `nvidia-smi memory.total` (whole GB, rounded down — multi-GPU splitting is
not attempted) and passes it to `select-model.sh`; if that read fails, `GPU_VRAM_GB` is empty and all fit
checks are skipped rather than guessed at.

`select-model.sh` also warns and requires an explicit `y` if the chosen model's `min_vram_gb` exceeds the
passed-in GPU VRAM figure, before printing the stdout assignments. Answering `y` is a deliberate user
override — the install proceeds normally with that model. Without a TTY this refuses (exits non-zero,
propagating through `install.sh`'s `eval` under `set -e`) rather than silently installing something that
won't fit.

`min_vram_gb` is hand-specified per entry rather than computed from weights + KV cache, so adding a model
means picking that number deliberately. Keep the list ordered smallest-to-largest — the menu prints it in
file order.

## Security model

This installer trusts several remote parties by design, and that's a deliberate tradeoff, not an
oversight:

- **Two `curl | bash` installs**: the `hf` CLI (`$HF_STANDALONE_INSTALLER`, `hf.co/cli/install.sh`) and
  the Qwen Code CLI (`$QWEN_STANDALONE_INSTALLER`, an Alibaba OSS-hosted script). Both are run via a
  live pipe, not downloaded-then-inspected, and neither is pinned to a hash. Every call site (normal run
  and `--install`) prints the exact URL immediately before executing it, and dry-run mode
  (`would "... curl ... | bash"`) shows the same command without running it — so the URL is visible
  before a user ever passes `--install`, not just discoverable by reading the source.
- **Model weights**: `hf download` pulls a GGUF blob from a third-party HF repo (`bartowski/...`). This
  is data, not executable code, but it's still a supply-chain trust point worth naming — a malicious or
  compromised GGUF isn't a known code-execution vector, but the repo owner isn't Alibaba/Qwen or a first
  party.
- **llama.cpp**: cloned from `ggml-org/llama.cpp` upstream and built from source (see commit-pinning note
  below) — the same trust level as any from-source dependency build.
- **MCP servers via `npx -y`**: `render_qwen_settings` configures two MCP servers,
  `@modelcontextprotocol/server-sequential-thinking` and `@modelcontextprotocol/server-memory` (both
  official MCP reference servers), to be launched with `npx -y` whenever Qwen Code starts them — `npx`
  fetches and runs the package on demand rather than something `install.sh` vets or pins a version of.

Mitigation approach taken: transparency over gating. No confirmation prompts, no `--no-verify` style
flag, no hash pinning — that would add friction to every run (violating the turnkey/idempotent design
goals above) in exchange for a checkbox users would habitually click through. Instead, each remote-script
step names its exact URL at the point of execution and in dry-run output, and this section documents the
trust boundaries once, up front, the same way the `0.0.0.0`/LAN-exposure tradeoff below is documented
rather than gated. If this policy changes (e.g. pinning installer scripts to a known-good hash, or
switching to download-then-exec so the script is inspectable before running), update both call sites in
`ensure_hf_cli` and `ensure_qwen_code` together, plus this section.

## Usage

- `./install.sh` — dry run (default). Prints what's already present and what would change; makes no
  changes.
- `./install.sh --install` (aliases: `--apply`, `-y`) — performs the actual installation.

## Design constraints preserved by the current implementation

- **Idempotency**: every step (`ensure_apt_packages`, `ensure_node`, `ensure_llama_cpp`, `ensure_model`,
  `ensure_qwen_code`, `configure_qwen_settings`, `write_launch_script`) checks current state before
  acting — dpkg queries, `command -v`, HEAD-vs-remote commit comparison plus a build stamp file
  (`build/.installed_commit`), file existence, and content diffing (for the settings JSON and launch
  script) — and is a no-op when already correct.
- **Turnkey**: exactly one interactive prompt — the model menu (and a second y/N only when the chosen
  model exceeds detected VRAM). Both accept `[enter]` for the safe path, and both fall back sensibly
  without a TTY. GPU presence is detected via `nvidia-smi`; everything else runs unattended once
  `--install` is passed.
- **8GB GPU assumption**: the catalog default (`qwen3.5-4b-q5`, ~3GB) leaves headroom under 8GB VRAM for
  the 65536-token KV cache at `-ngl 999` (full offload). Larger entries exist for bigger cards.

## Notes for future changes

- `check_gpu`'s error message (when `nvidia-smi` is missing) runs `ubuntu-drivers devices` itself (no
  sudo needed just to list), parses out the package tagged "recommended", and prints the exact
  `sudo apt install <pkg>` command for this machine — falling back to generic instructions only if
  `ubuntu-drivers` is absent or nothing is tagged recommended. This exists because the
  `ubuntu-drivers autoinstall`/`install` subcommands are not consistently available across Ubuntu
  releases (observed missing on 26.04).
- Version/commit pinning for llama.cpp is "latest tracked branch tip" (fast-forward merge to `@{u}`), not
  a pinned SHA — re-runs will pull and rebuild whenever upstream moves.
- The model repo/file, context size, and VRAM requirement come from `models.json`, not from constants in
  `install.sh`. Port and host remain constants at the top of the script; `LLAMA_DIR` is the only env-var
  override.
