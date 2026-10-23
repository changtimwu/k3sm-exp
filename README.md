# k3sm-exp

Experiments with [k3sm](https://k3sm.io), a Kubernetes distribution that runs Pods as native macOS processes.

## Installing k3sm

Based on the [k3sm quickstart](https://k3sm.io/docs/quickstart/).

### Requirements

- Apple Silicon (arm64) Mac
- macOS 26 or later

This host: Mac18,5, 32 GB RAM, macOS 27.0.1, k3sm v0.1.7 (Kubernetes v1.36.5).

### 1. Download and verify the release

The official one-liner is `curl -fsSL https://k3sm.io/install.sh | sh`. It downloads the release and then runs `sudo k3sm install`. To read the script first and keep the root step separate, download and verify only:

```sh
mkdir k3sm-release && cd k3sm-release
curl -fsSL https://k3sm.io/install.sh -o install.sh
less install.sh                                   # review it
K3SM_INSTALL_DOWNLOAD_ONLY=1 sh install.sh        # download + sha256-verify, no sudo
tar -xzf k3sm_*_darwin_arm64.tar.gz
./k3sm version
```

Set `K3SM_INSTALL_VERSION=v0.1.7` to pin a version. Without it, the script installs the newest release, which is a pre-release until the first stable tag.

### 2. Run the one-time admin install

```sh
sudo ./k3sm install
```

Run this in a real terminal. `sudo` needs a TTY for the password prompt, so it fails from a non-interactive shell, such as Claude Code's `!` prefix.

The install:

- copies k3sm to `/Library/k3sm` and links `/usr/local/bin/k3sm`
- creates the unprivileged `_k3sm` service user
- registers the `io.k3sm.server` and `io.k3sm.netd` LaunchDaemons, which start at boot
- adds a `k3sm` context to `~/.kube/config`

After this, day-to-day use doesn't need `sudo`. Don't also run `k3sm server` by hand, because the LaunchDaemon already runs it.

### 3. Verify

```sh
k3sm status              # exit code 0 = running; see `k3sm status --help`
k3sm kubectl get nodes   # one Ready darwin node
```

Right after install, `k3sm status` may report `degraded: 0/0 nodes ready` for about 15 seconds while the node registers. Some rows show `unknown` because their files are root-only. `sudo k3sm status` shows everything.

`kubectl` isn't installed on this host, so use `k3sm kubectl …`. Alternatively, `brew install kubectl` works with the `k3sm` context.

### 4. Run a test Pod

Pods run native Darwin executables, not Linux images. Every Pod needs the darwin `nodeSelector` and the `k3sm.io/provider` toleration, or admission rejects it.

```sh
k3sm kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hello
spec:
  nodeSelector:
    kubernetes.io/os: darwin
  tolerations:
    - key: k3sm.io/provider
      operator: Exists
      effect: NoSchedule
  restartPolicy: Never
  containers:
    - name: hello
      image: native
      command: ["/usr/bin/sw_vers"]
EOF

k3sm kubectl get pods     # hello  0/1  Completed
k3sm kubectl logs hello   # prints the host's macOS version
k3sm kubectl delete pod hello
```

## Serving an LLM with llama.cpp

`llama-server.yaml` runs llama.cpp's `llama-server` on the Metal GPU. It serves `ggml-org/Qwen3-1.7B-GGUF:Q4_K_M` through an OpenAI-compatible API and exposes it with a `LoadBalancer` Service on port 8080.

### Why a custom image

The pod sandbox denies every read under `/opt`. A pod that runs `image: native` with `/opt/homebrew/bin/llama-server` fails with `execve …: operation not permitted`, and its dylibs are "blocked by sandbox". k3sm has no setting to allow a host path. Instead, `llama-server-image/` packages the Homebrew build as a darwin/arm64 image:

- `bundle.sh` copies `llama-server`, its dylibs (llama, ggml, OpenSSL, libomp) and the ggml backend plugins (Metal, CPU, BLAS) into `ctx/`. It rewrites the load paths to `@rpath` and re-signs the files ad hoc. The backends sit next to the binary because ggml searches the executable's directory.
- `Dockerfile` is a COPY-only `FROM scratch` image, which `k3sm build` builds natively.

### Build and load the image

```sh
brew install llama.cpp
cd llama-server-image
./bundle.sh
k3sm build -t llama-server:0.7.0 --output llama-server-0.7.0.tar .
sudo k3sm image load llama-server-0.7.0.tar
```

`k3sm build` can't record the image in the node store as your user, because the runtimed socket belongs to `_k3sm`. That's why the image goes through a tarball and `sudo k3sm image load`. Run that last command in a real terminal.

### Deploy

```sh
k3sm kubectl apply -f llama-server.yaml
k3sm kubectl get pod llama-server -w      # Ready once the 1.3 GB GGUF has downloaded
```

The manifest includes:

- **PVC** `llama-models`, 5Gi, `local-path`. It holds the GGUF cache (`LLAMA_CACHE=/models`), so restarts don't download the model again.
- **Pod** with `imagePullPolicy: Never` and `mlx.k3sm.io/gpu: 1`, which grants Metal access. The GPU request needs a memory limit, set here to 6Gi.
- **`SSL_CERT_FILE=/etc/ssl/cert.pem`.** Homebrew OpenSSL's default CA bundle is under `/opt`, so without this the Hugging Face download fails with `SSL server verification failed`.
- **`HOME`.** k3sm pods start with `HOME` unset, so the manifest sets it.
- **Service** `type: LoadBalancer`. k3sm binds LoadBalancer ports on every host interface.

### Use it

| From | URL |
|---|---|
| This Mac | `http://localhost:8080/v1` |
| The LAN | `http://<mac-lan-ip>:8080/v1` (here: `192.168.1.151`) |
| Inside the cluster | `http://llama-server.default.svc:8080/v1` |

The advertised `EXTERNAL-IP` (`100.64.0.1`) can't be reached from other machines.

```sh
curl http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is Kubernetes? /no_think"}],"max_tokens":80}'
```

On this M6 Mac it measured about 2,300 tok/s for prompt processing and about 110 tok/s for generation.

The server has no API key and allows all CORS origins, and the port is open to the whole LAN. Add `--api-key <key>` to the pod args before using it on an untrusted network.

## Troubleshooting

- `k3sm status logs server` shows the server log.
- `k3sm doctor` runs diagnostics.
- Logs are in `/var/log/k3sm/`, and control-plane logs are in `/var/lib/k3sm/server/`.
- `sudo k3sm uninstall` removes k3sm and can be run more than once safely.
