#!/bin/sh
# CLIProxyAPI — zero-dependency bootstrap for Pterodactyl / bare hosts.
# Pulls the LATEST official release (static, no-plugin build) and runs it.
# Idempotent: re-running only re-downloads when the version changes.

set -eu
# Install into the working directory, not the script's own location. Panels
# often curl the script to /tmp and expect the server files beside the home dir.
cd "${INSTALL_DIR:-$PWD}"

PORT="${SERVER_PORT:-}"
[ -z "$PORT" ] && PORT="${SERVER_ALLOCATION_PORT:-}"
[ -z "$PORT" ] && PORT="${LISTEN_PORT:-}"
[ -z "$PORT" ] && PORT="${PORT:-}"

# Panels like Wispbyte hand every user a different allocation, and not all eggs
# export SERVER_PORT. Fall back to a remembered port, then ask, then default.
if [ -z "$PORT" ] && [ -f ".port" ]; then
  PORT=$(tr -d ' \t\r\n' < .port 2>/dev/null || true)
fi

if [ -z "$PORT" ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    echo "[cpa] No SERVER_PORT from the panel."
    printf '[cpa] Port to listen on [10000]: '
    read -r PORT_IN || PORT_IN=""
    PORT="${PORT_IN:-10000}"
  else
    PORT=10000
    echo "[cpa] WARN: panel provided no port; defaulting to $PORT (set SERVER_PORT to override)"
  fi
fi

# Validate and remember so a non-interactive restart reuses the same port.
case "$PORT" in
  ''|*[!0-9]*)
    echo "[cpa] ERROR: invalid port '$PORT' (must be numeric)" >&2
    exit 1
    ;;
esac
printf '%s' "$PORT" > .port 2>/dev/null || true
AUTH_DIR="auths"
BIN_DIR="bin"
mkdir -p "$BIN_DIR" "$AUTH_DIR"

CA="$PWD/ca-certificates.crt"

# Only export SSL_CERT_FILE for the binary when the system has no CA store;
# Go resolves certs from SSL_CERT_FILE first, so pointing it at our bundled copy
# is safe and fixes outbound TLS on minimal images.
if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/cert.pem ] && [ -f "$CA" ]; then
  export SSL_CERT_FILE="$CA"
fi

need() { command -v "$1" >/dev/null 2>&1; }

# If this script was piped/curled without the repo, the bundled CA is absent.
# Minimal eggs have no system store either, which would break every HTTPS call.
if [ ! -f "$CA" ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/cert.pem ]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 -o "$CA" "https://raw.githubusercontent.com/therealfreddied/cpa-pterodactyl/main/ca-certificates.crt" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$CA" "https://raw.githubusercontent.com/therealfreddied/cpa-pterodactyl/main/ca-certificates.crt" 2>/dev/null || true
  elif command -v node >/dev/null 2>&1; then
    node -e 'fetch("https://raw.githubusercontent.com/therealfreddied/cpa-pterodactyl/main/ca-certificates.crt").then(async r=>{if(!r.ok)process.exit(1);require("fs").writeFileSync(process.argv[1],Buffer.from(await r.arrayBuffer()));}).catch(()=>process.exit(1));' "$CA" 2>/dev/null || true
  fi
fi

# Alpine/minimal eggs ship busybox wget, which rejects --ca-certificate but
# trusts the system bundle at /etc/ssl/certs automatically. Only curl gets an
# explicit CA override, and only when the system store is missing.
USE_CA=""
if [ -f "$CA" ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/cert.pem ]; then
  USE_CA="$CA"
fi

node_fetch() { # url dest  -- uses Node's built-in fetch, no curl/wget needed
  node -e '
const fs=require("fs");
const [url,dest]=process.argv.slice(1);
fetch(url,{redirect:"follow"}).then(async r=>{
  if(!r.ok){console.error("HTTP "+r.status);process.exit(2);}
  const b=Buffer.from(await r.arrayBuffer());
  if(!b.length){console.error("empty");process.exit(3);}
  fs.writeFileSync(dest,b);
}).catch(e=>{console.error(e.message);process.exit(1);});
' "$1" "$2"
}

node_get() { # url
  node -e '
fetch(process.argv[1],{redirect:"follow"}).then(async r=>{
  if(!r.ok){process.exit(2);}
  process.stdout.write(Buffer.from(await r.arrayBuffer()));
}).catch(()=>process.exit(1));
' "$1"
}

fetch() { # url dest
  if need curl; then
    if [ -n "$USE_CA" ]; then
      curl -fsSL --cacert "$USE_CA" --retry 3 --retry-delay 2 --max-time 600 -o "$2" "$1"
    else
      curl -fsSL --retry 3 --retry-delay 2 --max-time 600 -o "$2" "$1"
    fi
  elif need wget; then
    # busybox-compatible invocation only
    wget -q -O "$2" "$1"
  elif need node; then
    node_fetch "$1" "$2"
  else
    echo "[cpa] ERROR: need curl, wget, or node on this host" >&2
    exit 1
  fi
}

api_get() { # url
  if need curl; then
    if [ -n "$USE_CA" ]; then
      curl -fsSL --cacert "$USE_CA" --retry 2 --max-time 30 "$1"
    else
      curl -fsSL --retry 2 --max-time 30 "$1"
    fi
  elif need wget; then
    wget -q -O - "$1" 2>/dev/null
  elif need node; then
    node_get "$1"
  fi
}

# ---------- platform ----------
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *)
    echo "[cpa] ERROR: unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

# ---------- resolve version ----------
REQ="${CPA_VERSION:-latest}"
if [ "$REQ" = "latest" ]; then
  TAG=$(api_get "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)
  if [ -z "${TAG:-}" ]; then
    echo "[cpa] WARN: could not reach GitHub API, using bundled default" >&2
    TAG="v8.0.35"
  fi
else
  case "$REQ" in v*) TAG="$REQ" ;; *) TAG="v$REQ" ;; esac
fi

CUR=""
[ -f "$BIN_DIR/.version" ] && CUR=$(cat "$BIN_DIR/.version" 2>/dev/null || true)

if [ "$CUR" = "$TAG" ] && [ -x "$BIN_DIR/CLIProxyAPI" ]; then
  echo "[cpa] already at $TAG (cached)"
else
  VER="${TAG#v}"
  URL="https://github.com/router-for-me/CLIProxyAPI/releases/download/${TAG}/CLIProxyAPI_${VER}_linux_${ARCH}_no-plugin.tar.gz"
  echo "[cpa] fetching $TAG (linux/$ARCH, static)"
  TMP=$(mktemp -d 2>/dev/null || echo "./.tmp.$$")
  mkdir -p "$TMP"
  if ! fetch "$URL" "$TMP/cpa.tar.gz"; then
    echo "[cpa] ERROR: download failed: $URL" >&2
    echo "[cpa] hint: this host may block github.com — set CPA_VERSION to a pinned tag" >&2
    rm -rf "$TMP"
    exit 1
  fi
  tar -xzf "$TMP/cpa.tar.gz" -C "$TMP" 2>/dev/null || {
    echo "[cpa] ERROR: could not extract archive" >&2
    rm -rf "$TMP"; exit 1
  }
  SRC=""
  for c in "$TMP/cli-proxy-api" "$TMP/CLIProxyAPI"; do
    [ -f "$c" ] && { SRC="$c"; break; }
  done
  if [ -z "$SRC" ]; then
    echo "[cpa] ERROR: no binary inside archive" >&2
    ls -la "$TMP" >&2
    rm -rf "$TMP"; exit 1
  fi
  mv "$SRC" "$BIN_DIR/CLIProxyAPI"
  chmod +x "$BIN_DIR/CLIProxyAPI"
  echo "$TAG" > "$BIN_DIR/.version"
  if [ -f "$TMP/config.example.yaml" ]; then
    cp "$TMP/config.example.yaml" "./config.example.yaml" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  echo "[cpa] installed $TAG"
fi

# ---------- api key ----------
KEYFILE=".apikey"
if [ -z "${CPA_API_KEY:-}" ]; then
  if [ -f "$KEYFILE" ]; then
    CPA_API_KEY=$(cat "$KEYFILE")
  else
    CPA_API_KEY="sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s' "$CPA_API_KEY" > "$KEYFILE"
    chmod 600 "$KEYFILE" 2>/dev/null || true
    echo ""
    echo "=============================================================="
    echo "  Generated API key (stored in .apikey):"
    echo "  $CPA_API_KEY"
    echo "=============================================================="
    echo ""
  fi
fi

# ---------- config ----------
cat > config.yaml <<YAML
config-version: 8
server:
  host: "0.0.0.0"
  port: ${PORT}
access:
  api-keys:
    - "${CPA_API_KEY}"
oauth:
  auth-dir: "./${AUTH_DIR}"
observability:
  logs:
    debug: false
    request-log: false
    logging-to-file: false
routing:
  session-affinity-subagents: true
plugins:
  enabled: false
YAML

echo "[cpa] starting on 0.0.0.0:${PORT}"
echo "[cpa] auth dir: $PWD/$AUTH_DIR"
exec ./bin/CLIProxyAPI -config ./config.yaml
