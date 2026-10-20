#!/bin/sh
# CLIProxyAPI — zero-dependency bootstrap for Pterodactyl / bare hosts.
# Pulls the LATEST official release (static, no-plugin build) and runs it.
# Idempotent: re-running only re-downloads when the version changes.

set -eu
cd "$(dirname "$0")"

PORT="${SERVER_PORT:-${PORT:-10000}}"
AUTH_DIR="auths"
BIN_DIR="bin"
mkdir -p "$BIN_DIR" "$AUTH_DIR"

# Only export SSL_CERT_FILE for the binary when the system has no CA store;
# Go resolves certs from SSL_CERT_FILE first, so pointing it at our bundled copy
# is safe and fixes outbound TLS on minimal images.
if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/cert.pem ] && [ -f "$CA" ]; then
  export SSL_CERT_FILE="$CA"
fi

need() { command -v "$1" >/dev/null 2>&1; }

CA="$PWD/ca-certificates.crt"

# Alpine/minimal eggs ship busybox wget, which rejects --ca-certificate but
# trusts the system bundle at /etc/ssl/certs automatically. Only curl gets an
# explicit CA override, and only when the system store is missing.
USE_CA=""
if [ -f "$CA" ] && [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/ssl/cert.pem ]; then
  USE_CA="$CA"
fi

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
  else
    echo "[cpa] ERROR: need curl or wget on this host" >&2
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
