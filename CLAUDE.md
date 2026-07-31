# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Implemented as a single script: `install.sh`. It is a bash installer with no build system, tests, or
dependencies beyond what it shells out to (apt, git, cmake, jq, hf, curl).

## Purpose

An idempotent, turnkey installation tool that prepares a laptop to run a small local LLM stack. Target
hardware assumption: an NVIDIA GPU with ~8GB VRAM (requires `nvidia-smi`; the script exits if not found).

`install.sh` sets up:
1. **Model**: `bartowski/Qwen_Qwen3.5-4B-GGUF`, file `Qwen_Qwen3.5-4B-Q6_K_L.gguf` (~4GB), downloaded via
   the `hf`/`huggingface-cli` tool into the standard `~/.cache/huggingface/hub` cache.
2. **llama.cpp**: cloned to `~/llama.cpp` (override with `LLAMA_DIR`) and built from source with
   `-DGGML_CUDA=ON`. If `llama-server` is already on `PATH`, the build (and the `nvcc` check below) is
   skipped entirely and that binary is used instead. Otherwise, before building, `ensure_cuda_compiler`
   checks for `nvcc` on `PATH` and installs it via `apt` (`nvidia-cuda-toolkit`) if missing — plain
   `build-essential` only provides gcc/g++, which cannot compile the CUDA kernels.
3. **Qwen Code CLI**: installed via the official standalone installer script (curl | bash) if `qwen` is
   not already on `PATH`.

It also configures `~/.qwen/settings.json` (via `jq`) to add/update an `openai`-compatible model provider
pointing at llama-server, and writes a `launch.sh` into the llama.cpp directory that starts
`llama-server` with `-ngl 999` (full GPU offload) and a 65536-token context size.

`launch.sh` binds llama-server to `--host 0.0.0.0` (all interfaces), not just loopback, so the API is
reachable from other devices on the same LAN — e.g. a phone or laptop running Qwen Code pointed at this
machine. The Qwen settings provider URL is set to the machine's detected LAN IP (`detect_lan_ip`, via
`ip route get` falling back to `hostname -I`) rather than `127.0.0.1`, for the same reason. llama-server
itself has no auth and permissive CORS by default (it prints its own warning about this at startup) —
combined with the `0.0.0.0` bind, the API is unauthenticated and reachable by anything on the LAN. That's
an intentional tradeoff for a trusted home network, not an oversight; don't quietly narrow it back to
loopback-only without checking whether LAN reachability is still wanted.

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

- **Idempotency**: every step (`ensure_apt_packages`, `ensure_llama_cpp`, `ensure_model`,
  `ensure_qwen_code`, `configure_qwen_settings`, `write_launch_script`) checks current state before
  acting — dpkg queries, `command -v`, HEAD-vs-remote commit comparison plus a build stamp file
  (`build/.installed_commit`), file existence, and content diffing (for the settings JSON and launch
  script) — and is a no-op when already correct.
- **Turnkey**: no interactive prompts; GPU presence is detected via `nvidia-smi`, and all install steps
  run unattended once `--install` is passed.
- **8GB GPU assumption**: a ~4GB Q6_K_L quantization leaves headroom under 8GB VRAM for the 65536-token
  KV cache at `-ngl 999` (full offload).

## Notes for future changes

- `check_gpu`'s error message (when `nvidia-smi` is missing) runs `ubuntu-drivers devices` itself (no
  sudo needed just to list), parses out the package tagged "recommended", and prints the exact
  `sudo apt install <pkg>` command for this machine — falling back to generic instructions only if
  `ubuntu-drivers` is absent or nothing is tagged recommended. This exists because the
  `ubuntu-drivers autoinstall`/`install` subcommands are not consistently available across Ubuntu
  releases (observed missing on 26.04).
- Version/commit pinning for llama.cpp is "latest tracked branch tip" (fast-forward merge to `@{u}`), not
  a pinned SHA — re-runs will pull and rebuild whenever upstream moves.
- The model file/repo, port, and context size are set as constants at the top of `install.sh`; there is
  no config file or CLI flag to override them (aside from `LLAMA_DIR` via env var).
