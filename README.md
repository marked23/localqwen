# localqwen

A one-shot installer that sets up [Qwen Code](https://github.com/QwenLM/qwen-code) running
entirely on your own machine, backed by a local LLM — no API key, no cloud, no bill.

It's aimed at people who want to *try* a local coding assistant on modest hardware without
figuring out llama.cpp, GGUF quantizations, or CLI configuration by hand. Point it at a laptop
with an 8GB NVIDIA GPU and run one command.

## Fair warning

This is a shell script you found on the internet, and running it means trusting the people who
wrote it. Worth knowing before you do:

- **It curls and executes other shell scripts.** Installing the `hf` CLI and the Qwen Code CLI
  both work by piping an installer script straight from its source into `bash`, unpinned. You're
  trusting those upstreams (Hugging Face, Alibaba) as much as you're trusting this repo.
- **It downloads a model from a third party.** The GGUF weights come from a community repo on
  Hugging Face (`bartowski/...`), not from Qwen or Alibaba directly. It's data rather than code,
  but it's still a supply-chain link outside this project's control.
- **It builds and runs software from source.** llama.cpp is cloned from upstream and compiled on
  your machine.
- **It exposes an unauthenticated API on your LAN.** `launch.sh` binds llama-server to
  `0.0.0.0`, and Qwen Code is pointed at your machine's LAN IP rather than `localhost`. That's
  intentional — it's what lets a phone or another laptop on the same network use it — but it
  means anything else on your network can reach it too.

None of this is unusual for dev tooling (plenty of popular install scripts work exactly this
way), and the script prints every URL it's about to run before it runs it — dry-run mode shows
you the same thing without executing anything. Read the output, look at `install.sh` if you want
to see for yourself, and run it on a network and machine you trust.

## What it does

Running `install.sh` gets you, end to end:

1. **A model** — [`Qwen_Qwen3.5-4B-Q6_K_L.gguf`](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF)
   (~4GB), a quantization sized to leave headroom on an 8GB card, downloaded via the
   `huggingface_hub` CLI.
2. **llama.cpp** — cloned and built from source with CUDA support, so the model runs on your
   GPU. If you already have `llama-server` on your `PATH`, this step is skipped and your
   existing build is used.
3. **Qwen Code CLI** — installed via the official installer, if not already present.
4. **Wiring** — `~/.qwen/settings.json` is updated to point Qwen Code at an OpenAI-compatible
   endpoint on `http://127.0.0.1:8080/v1`, and a `launch.sh` script is dropped into the
   llama.cpp directory that starts `llama-server` with full GPU offload (`-ngl 999`) and a
   65536-token context window.

That's it — no config files to hand-edit, no flags to tune. The script is intentionally
opinionated: one model, one port, one context size, one way of wiring things together.

## Requirements

- Linux with `apt` (Debian/Ubuntu-based)
- An NVIDIA GPU with drivers installed (`nvidia-smi` must work) — 8GB VRAM is the target,
  though anything with less headroom may struggle at the full context size
- `sudo` access (to install build dependencies via apt)
- `git`, `curl`

Everything else (`cmake`, `build-essential`, `python3`, `jq`, etc.) is installed automatically.

## Usage

```bash
git clone <this-repo>
cd localqwen
./install.sh
```

With no arguments, this is a **dry run**: it checks your system and prints exactly what it
would install or change, but makes no changes. Read through the output before doing anything
else.

When you're ready:

```bash
./install.sh --install
```

This performs the actual installation. It's safe to re-run at any time — every step checks
whether it's already done before doing anything, so re-running just confirms your setup is
current (and picks up llama.cpp updates if any are available upstream).

### Running it

Once installed, start the model server:

```bash
~/llama.cpp/launch.sh
```

Then, in another terminal:

```bash
qwen
```

Qwen Code will talk to the local server instead of a cloud API.

## Notes

- `LLAMA_DIR` (default `~/llama.cpp`) can be overridden via environment variable if you want
  llama.cpp cloned/built somewhere else.
- llama.cpp is tracked at the tip of its default branch, not a pinned version — re-running the
  installer will pull and rebuild whenever upstream moves.
- The model, port, and context size are fixed constants at the top of `install.sh`. This is by
  design: the goal is a working setup with zero decisions required, not a general-purpose
  configuration tool. If you want something different, edit the constants directly.

## Disclaimer

This project is not affiliated with Qwen, Alibaba, or the llama.cpp project. It just automates
downloading and wiring together their existing, official tools.
