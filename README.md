# Aura, self-hosted

Aura is a set of Docker images plus one compose file, `compose.yaml`. No clone, no build, no scripts required.

## On any machine

1. Install Docker (Engine 24+ with Compose v2.23+, or Docker Desktop).
2. Get the file, generate the three secrets, and start it, in one command:

   ```bash
   mkdir aura && cd aura
   curl -fsSL https://raw.githubusercontent.com/ThePixelExpert/aura/main/install.sh | sh
   ```

   This downloads `compose.yaml`, fills in `api_token`, `master_key` and `broker_token` with
   fresh random values (and prints the `master_key` once so you can back it up), then runs
   `docker compose up -d`. Safe to re-run — if the secrets are already set, it skips straight
   to starting the stack.

   Prefer to do it by hand, with no script at all? Download just the compose file and replace
   the three `CHANGE_ME` values yourself (the file's comments say how to generate each):

   ```bash
   mkdir aura && cd aura
   curl -fsSLO https://raw.githubusercontent.com/ThePixelExpert/aura/main/compose.yaml
   # edit the three CHANGE_ME values, then:
   docker compose up -d
   ```

3. Open <http://localhost:3010>, go to Settings -> AI Providers, and add your provider key.

That is the whole setup. `docker compose pull && docker compose up -d` updates; `docker compose down` stops (your data stays in Docker volumes).

## What you can set (all in `compose.yaml`)

| Setting | Where | Default |
| --- | --- | --- |
| Secrets (`api_token`, `master_key`, `broker_token`) | top of the file | must be set; the UI refuses to start with the placeholder |
| Address you browse to | `x-address` + `frontend.ports` | `http://localhost:3010`, this machine only |
| Login in front of the UI | `frontend.environment.AURA_UI_BASIC_AUTH` | none (fine on loopback; required before exposing) |
| Which model does what | `x-models` | see below |
| Local models on/off | `AURA_HOSTED_ONLY` + `--profile models` | off: bring your own provider key |
| GPU for local models | auto-enabled by `install.sh` if an NVIDIA GPU is usable; by hand, uncomment `deploy:` under `ollama` | CPU |
| Where your files live | `backend.volumes` | Docker volume `vault` (a host folder works too, owned by uid 1000) |

Back up the `master_key` and the `vault` and `data` volumes.

## Local models

Set `AURA_HOSTED_ONLY: "0"` and start with `docker compose --profile models up -d` (or re-run `install.sh`, which does this check
every time). The first start downloads the models named in `x-models`. Edit that block to choose models per job, then run the same
command again.

**GPU:** if you have an NVIDIA GPU with the NVIDIA Container Toolkit installed, `install.sh` detects it (checks that `nvidia-smi`
works and that Docker has the `nvidia` runtime registered) and enables GPU acceleration automatically — nothing to edit by hand.
Verify a model is actually using it with `docker exec aura-nas-ollama nvidia-smi`. Once the GPU is visible to the container, Ollama
decides on its own how much of a model fits in VRAM and spills the rest to system RAM/CPU — that part needs no configuration either
way. Running `docker compose` directly instead of `install.sh`? Uncomment the `deploy:` block under `ollama` in `compose.yaml`
yourself. AMD/Intel GPUs aren't auto-detected (different image/device setup, e.g. ROCm) — happy to add that if you need it.

**Don't have the NVIDIA driver / Container Toolkit yet?** `nvidia-smi` failing, or `install.sh` printing "No usable NVIDIA GPU
detected", usually means one of these two pieces is missing:

- **Linux, native Docker Engine** (most self-hosts): install the driver via your distro — Ubuntu/Debian:
  `sudo ubuntu-drivers autoinstall` (or `sudo apt install nvidia-driver-<version>` for a specific branch), reboot, then confirm
  with `nvidia-smi`. Then add the NVIDIA Container Toolkit:
  ```bash
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt update && sudo apt install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  ```
  (Full steps, other distros: <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>.)
  Then just re-run `install.sh` (or `./install.sh` if you already have `compose.yaml`) — it picks the GPU up automatically.
- **Windows with Docker Desktop (WSL2 backend)**: install the regular NVIDIA GeForce/Studio driver *on Windows itself*, not
  inside WSL — it already includes WSL GPU support, and Docker Desktop passes the GPU through on its own. No Container
  Toolkit step needed inside WSL. Confirm with `nvidia-smi` inside your WSL distro; if that works, Docker already has it.
- **macOS**: not supported. Docker Desktop on Mac has no GPU passthrough at all (Apple Silicon has no NVIDIA GPU, and Intel
  Macs can't pass one through either) — local models there always run on CPU, GPU or not.

| Role | Job | Default |
| --- | --- | --- |
| `PARENT` | The model you chat with; plans and calls tools. Biggest effect on quality. | `gemma4:e4b` |
| `WORKER` | Sub-agents Aura delegates pieces of a task to | `gemma4:e4b` |
| `SUMMARY` | Titles, summaries, memory upkeep. Small and fast is fine. | `qwen3.5:4b` |
| `OCR` | Text from images and scanned PDFs | `glm-ocr` |
| `CODER` | Optional: edits an app's code when you comment on it | none |

Any tag from <https://ollama.com/library> works. Already run Ollama, LiteLLM or vLLM elsewhere? Skip the profile and point
`MODEL_GATEWAY_URL` / `MODEL_GATEWAY_KEY` at it. Image generation and voice are not included.

## What runs

| Container | Job | Exposed |
| --- | --- | --- |
| `aura-nas-frontend` | Web UI and the only door to the API | `127.0.0.1:3010` |
| `aura-nas-backend` | The Aura engine and API | none |
| `aura-nas-sandbox` | Where Aura's shell and browser tools run | none |
| `aura-nas-docker-proxy` | Lets the backend `docker exec` into the sandbox, nothing else | none |
| `aura-nas-apps-broker` | Builds and runs small web apps Aura creates | none |
| `aura-nas-ollama`, `aura-nas-model-puller` | Only with `--profile models` | none |

`docker-proxy` and `apps-broker` mount the Docker socket (root-equivalent on the host), which is why each is small, filtered
and unpublished. Delete `apps-broker` if you do not want Aura to start containers. The container names are fixed because the
proxy's rules name them, so only one Aura per Docker host.

## Privacy

Aura sends data only to the provider you choose. One-click Google/Microsoft sign-in uses Edwards Tech's relay and only when you
click it (set `AURA_CONNECT_URL` for your own relay; email app passwords and calendar links need no relay).

## Troubleshooting

- **UI exits at start**: a `CHANGE_ME` is still in the file — run `install.sh` (works on an existing `compose.yaml` too), or set the three secrets by hand. **Backend errors about the master key**: it must be exactly 32 random bytes, base64url.
- **Model download hangs on DNS**: a strict host firewall may only allow DNS from the address ranges it knew about; Docker moves to a new range when the old one is used up. Remove unused networks (`docker network prune`) or allow DNS from the new range.
- **Port in use**: change the left side of `127.0.0.1:3010:80`, and `x-address` to match.

## License

Sustainable Use License: free for personal and internal business use; redistribution only free and non-commercial. Third-party
components keep their own licenses (see `THIRD_PARTY_NOTICES`).

The images are linux/amd64; arm64 is untested.
