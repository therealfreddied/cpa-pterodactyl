# CLIProxyAPI — one-command deploy for Pterodactyl / bare hosts

Runs the **latest official [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** release.
No Docker. No root. No build step.

## Why the `no-plugin` build

The default release is dynamically linked and requires `GLIBC_2.32+`.
That fails on Alpine (musl) and Debian 11, which is what most free bot-hosting
eggs actually run. The `no-plugin` release is **statically linked** and runs on
anything — verified on Alpine 3.20, Debian 11, and Debian 12.

## RAM

Measured in a hard cgroup with swap disabled:

| Metric | Value |
|---|---|
| Steady RSS | **23 MB** |
| Peak (startup) | **159 MB** |
| OOM kills at 256 MB cap | **0** |

Runs comfortably on a **256 MB** allocation. 512 MB if you want headroom.

## Deploy

**Pterodactyl / bot panel:** upload this repo, set the startup command to:

```
sh start.sh
```

**Any Linux box:**

```sh
git clone https://github.com/therealfreddied/cpa-pterodactyl.git
cd cpa-pterodactyl
SERVER_PORT=10000 sh start.sh
```

First run downloads the binary (~23 MB) and prints a generated API key.
Later runs start in under a second from cache.

## What it does automatically

1. Detects architecture (`x86_64` → `amd64`, `aarch64` → `aarch64`)
2. Resolves the **latest** release tag from the GitHub API
3. Skips the download if that version is already cached in `bin/`
4. Downloads and extracts the **static** `no-plugin` build
5. Writes `config.yaml` bound to `0.0.0.0` on `$SERVER_PORT`
6. Generates and persists an API key in `.apikey` (mode 600)
7. Exports `SSL_CERT_FILE` so outbound TLS works on minimal images
8. `exec`s the binary so the panel supervises the real process

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SERVER_PORT` | `10000` | Port to bind (Pterodactyl sets this) |
| `CPA_API_KEY` | generated | Override the API key instead of using `.apikey` |
| `CPA_VERSION` | `latest` | Pin a tag, e.g. `v8.0.35` |

## Adding provider credentials

Drop OAuth JSON files into `auths/`. The server watches that directory and
reloads automatically — no restart needed.

```
auths/
  antigravity-you@example.com.json
```

## Verify

```sh
curl -i http://127.0.0.1:10000/healthz          # 200 {"status":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:10000/v1/models              # 401 (locked)
curl -s -H "Authorization: Bearer $(cat .apikey)" \
  http://127.0.0.1:10000/v1/models              # {"data":[...]}
```

## Disk

~68 MB for the binary plus your auth files. Fits a 1 GB egg with room to spare.

## Notes

- Nothing is exposed beyond the port you bind. Bind `127.0.0.1` instead if the
  host gives you no firewall.
- `config.yaml`, `bin/`, `.apikey`, and `auths/` are gitignored — your keys and
  credentials never end up in the repo.
