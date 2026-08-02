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
- **It downloads a model from a third party.** The GGUF weights come from community repos on
  Hugging Face (`unsloth/...`, `bartowski/...` — see [`models.json`](models.json)), not from Qwen
  or Alibaba directly. It's data rather than code, but it's still a supply-chain link outside
  this project's control.
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

1. **A model, chosen by you** — the script detects your GPU's VRAM and shows a menu of models
   from [`models.json`](#the-model-catalog-modelsjson), marking which ones fit and which are too
   big for your card. Pick one (or press enter for the suggested default), and it's downloaded
   via the `hf` CLI into the standard `~/.cache/huggingface/hub` cache.
2. **llama.cpp** — cloned and built from source with CUDA support, so the model runs on your
   GPU. If you already have `llama-server` on your `PATH`, this step is skipped and your
   existing build is used.
3. **Qwen Code CLI** — installed via the official installer, if not already present.
4. **Wiring** — `~/.qwen/settings.json` is updated to point Qwen Code at an OpenAI-compatible
   endpoint on `http://<your-lan-ip>:8080/v1`, and a `launch.sh` script is dropped into this
   repo's folder that starts `llama-server` with full GPU offload (`-ngl 999`) and the context
   size of whichever model you picked.

That's it — no config files to hand-edit, no flags to tune beyond the one model choice. The
script is intentionally opinionated: one port, one way of wiring things together, and a model
menu instead of a maze of settings.

## The model catalog (`models.json`)

[`models.json`](models.json) is the list of models the installer can offer you. Each entry has:

| field              | meaning                                                         |
|--------------------|------------------------------------------------------------------|
| `id`               | stable identifier, also used as the `--model` name in Qwen Code |
| `name`             | display name shown in the menu                                  |
| `repo` / `file`    | Hugging Face repo and GGUF filename to download                 |
| `context_size`     | context window llama-server is launched with                    |
| `min_vram_gb`      | hand-picked estimate of VRAM needed to run it comfortably        |
| `download_size_gb` | approximate download size                                       |
| `description`      | one-line blurb shown in the menu                                |

A top-level `default` field names which `id` is pre-selected (just press enter to take it).

[`select-model.sh`](select-model.sh) is the standalone script that reads `models.json`, prints
the numbered menu (smallest VRAM requirement first, marking each entry `fits` or `too big for
your <N>GB GPU` based on your detected card), and reads your choice. `install.sh` shells out to
it and captures the result — the menu and prompts go to your terminal (stderr), while the
selected model's fields are handed back to `install.sh` on stdout. If you pick a model whose
`min_vram_gb` exceeds what was detected on your card, it'll ask you to confirm before continuing.

Want to try a different model later? Just re-run `./install.sh --install` and pick a different
entry from the menu — it downloads the new model, rewrites `launch.sh` and your Qwen Code
settings to point at it, and leaves any previously-downloaded models in the Hugging Face cache
untouched.

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

This performs the actual installation. Partway through, it'll show you a menu of models from
`models.json` — pick one by number, or press enter to take the suggested default. Everything
else proceeds unattended (the only other prompt is a confirmation if you deliberately pick a
model too big for your detected VRAM).

It's safe to re-run at any time — every step checks whether it's already done before doing
anything, so re-running just confirms your setup is current (and picks up llama.cpp updates if
any are available upstream, or lets you switch to a different model from the menu).

### Running it

Once installed, run (from the `localqwen` folder):

```bash
./launch.sh
```

This starts the model server in the background, waits until it's ready, and then launches
`qwen` in the same terminal — talking to the local server instead of a cloud API. Closing that
terminal (or exiting `qwen`) stops the server too.

## Notes

- `LLAMA_DIR` (default `~/llama.cpp`) can be overridden via environment variable if you want
  llama.cpp cloned/built somewhere else.
- llama.cpp is tracked at the tip of its default branch, not a pinned version — re-running the
  installer will pull and rebuild whenever upstream moves.
- The model is the one deliberate choice in this tool — picked from the menu described in
  [The model catalog](#the-model-catalog-modelsjson). Port and context size are not: port is a
  fixed constant at the top of `install.sh`, and context size comes from whichever model you
  picked in `models.json`. Add a new model by adding an entry to `models.json`; there's nothing
  else to edit.

## Disclaimer

This project is not affiliated with Qwen, Alibaba, or the llama.cpp project. It just automates
downloading and wiring together their existing, official tools.
