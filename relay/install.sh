#!/usr/bin/env sh
# Haven relay — one-command setup to be your circle's always-on mailbox.
#
# THE EASY WAY (default): install the `haven-relay` static binary and run it. It links to
# your circle and serves BOTH roles — live connection relay AND the sealed-media mailbox —
# straight off THIS machine's local disk, over Haven Net (iroh). No cloud, no S3, no ports,
# no domain, no config. Every blob it stores is end-to-end sealed to your circle, so the
# relay can never read anything.
#
#   curl -fsSL https://wemiller.com/apps/haven/relay/install.sh | sh
#   # then:
#   haven-relay run --link "haven-relay://circle#...."   # paste the link the app shows you
#   haven-relay run                                       # restart later: reuses the saved link
#
# THE CLASSIC WAY (--bucket): self-host a plain S3 bucket with `rclone serve s3` and point
# Haven at it (needs a public IP / port-forward / VPS). Prefer a managed bucket (R2/B2/S3)?
# You don't need this script — see README.md.
#
# Usage:
#   sh install.sh                       # install the haven-relay binary (recommended)
#   sh install.sh --bucket [--native]   # classic rclone-serve-s3 bucket instead
#   sh install.sh --bucket --port 8333 --dir ~/haven-bridge
set -eu

MODE=relay        # relay | bucket
BUCKET_MODE=docker
PORT=8333
DATADIR="${HAVEN_BRIDGE_DIR:-$HOME/haven-bridge}"
BUCKET=haven
PREFIX="${PREFIX:-$HOME/.local/bin}"
REPO="${HAVEN_RELAY_REPO:-blaineam/haven}"   # GitHub releases host the prebuilt binaries

while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) MODE=bucket ;;
    --native) BUCKET_MODE=native ;;
    --port)   PORT="$2"; shift ;;
    --dir)    DATADIR="$2"; shift ;;
    --prefix) PREFIX="$2"; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
  shift
done

OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"

# ─────────────────────────────────────────────────────────────────────────────────────
# THE EASY WAY — install the haven-relay static binary.
# ─────────────────────────────────────────────────────────────────────────────────────
install_relay() {
  case "$OS-$ARCH" in
    Linux-x86_64)   TARGET="x86_64-unknown-linux-musl" ;;
    Linux-aarch64)  TARGET="aarch64-unknown-linux-musl" ;;
    Darwin-arm64)   TARGET="aarch64-apple-darwin" ;;
    Darwin-x86_64)  TARGET="x86_64-apple-darwin" ;;
    *) echo "✗ No prebuilt haven-relay for $OS-$ARCH."
       echo "  Build from source:  cd core && cargo build --release -p haven-relay"
       exit 1 ;;
  esac

  mkdir -p "$PREFIX"
  URL="https://github.com/${REPO}/releases/latest/download/haven-relay-${TARGET}"
  echo "▸ Downloading haven-relay ($TARGET)…"
  if curl -fsSL "$URL" -o "$PREFIX/haven-relay"; then
    chmod +x "$PREFIX/haven-relay"
  else
    echo "✗ Could not download a prebuilt binary (no release asset yet for $TARGET?)."
    echo "  Build from source instead:"
    echo "      git clone https://github.com/${REPO} && cd haven/core"
    echo "      cargo build --release -p haven-relay"
    echo "      cp target/release/haven-relay \"$PREFIX/\""
    exit 1
  fi

  echo
  echo "═══════════════════════════════════════════════════════════════"
  echo "✓ Installed: $PREFIX/haven-relay"
  case ":$PATH:" in
    *":$PREFIX:"*) : ;;
    *) echo "  (add $PREFIX to your PATH, or run it by full path)" ;;
  esac
  cat <<'EOF'

Now make it your circle's mailbox in two steps:

  1. In the Haven app:  You → Advanced → Relay → "Add a relay"
     It shows a relay link (haven-relay://circle#...). Copy it.

  2. On this machine:
       haven-relay run --link "haven-relay://circle#...."

That's it. It prints a QR + the link (so you can re-add it in the app any time),
generates and SAVES its own identity, creates ~/.haven-relay/store, and serves your
circle's sealed-media mailbox from local disk over Haven Net. Leave it running.

  • Restart later with no arguments:   haven-relay run
  • Keep it always-on (Linux):
      (crontab -e)  →  @reboot $HOME/.local/bin/haven-relay run >/dev/null 2>&1
    or a one-line systemd user service (see README.md).

The relay only ever moves ciphertext. It cannot read your circle's content.
═══════════════════════════════════════════════════════════════
EOF
}

# ─────────────────────────────────────────────────────────────────────────────────────
# THE CLASSIC WAY — self-host an S3 bucket with rclone serve s3.
# ─────────────────────────────────────────────────────────────────────────────────────
start_bucket() {
  mkdir -p "$DATADIR/data/$BUCKET"   # the folder named '$BUCKET' IS the S3 bucket

  CREDFILE="$DATADIR/.haven-bridge-creds"
  if [ -f "$CREDFILE" ]; then
    . "$CREDFILE"
  else
    AKEY="haven$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    SKEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf 'AKEY=%s\nSKEY=%s\n' "$AKEY" "$SKEY" > "$CREDFILE"
    chmod 600 "$CREDFILE"
  fi

  echo "▸ Haven bucket (rclone serve s3 — MIT)  OS=$OS ARCH=$ARCH mode=$BUCKET_MODE"
  echo "▸ Data dir: $DATADIR"

  if [ "$BUCKET_MODE" = docker ]; then
    command -v docker >/dev/null 2>&1 || { echo "✗ Docker not found. Re-run with --native."; exit 1; }
    docker rm -f haven-bridge >/dev/null 2>&1 || true
    docker run -d --name haven-bridge --restart unless-stopped \
      -p "$PORT:8333" -v "$DATADIR/data:/data" \
      rclone/rclone serve s3 /data --addr :8333 --auth-key "$AKEY,$SKEY" >/dev/null
    echo "✓ rclone serve s3 running in Docker (container: haven-bridge, auto-restarts)."
  else
    BIN="$DATADIR/rclone"
    if ! command -v rclone >/dev/null 2>&1 && [ ! -x "$BIN" ]; then
      case "$OS-$ARCH" in
        Linux-x86_64)  RC="linux-amd64" ;;
        Linux-aarch64) RC="linux-arm64" ;;
        Darwin-arm64)  RC="osx-arm64" ;;
        Darwin-x86_64) RC="osx-amd64" ;;
        *) echo "✗ No native rclone build for $OS-$ARCH. Use Docker (drop --native)."; exit 1 ;;
      esac
      echo "▸ Downloading rclone ($RC)…"
      curl -fsSL "https://downloads.rclone.org/rclone-current-${RC}.zip" -o "$DATADIR/rclone.zip"
      unzip -oj "$DATADIR/rclone.zip" '*/rclone' -d "$DATADIR" >/dev/null
      rm -f "$DATADIR/rclone.zip"; chmod +x "$BIN"
    fi
    RCLONE="$(command -v rclone || echo "$BIN")"
    nohup "$RCLONE" serve s3 "$DATADIR/data" --addr ":$PORT" --auth-key "$AKEY,$SKEY" \
      >"$DATADIR/rclone.log" 2>&1 &
    echo "✓ rclone serve s3 running natively (pid $!, log: $DATADIR/rclone.log)."
  fi

  LANIP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 127.0.0.1)"
  cat <<EOF

═══════════════════════════════════════════════════════════════
✓ Your Haven bucket is live (rclone serve s3 — MIT, fully open source).

Paste these into Haven → You → Advanced → Storage → Custom S3 bucket,
then turn on "Volunteer as tribute":

   Endpoint:    $LANIP:$PORT
   Region:      us-east-1
   Bucket:      $BUCKET
   Access key:  $AKEY
   Secret key:  $SKEY

• For your circle to reach it from anywhere, expose the port (router
  port-forward, Tailscale, or a small VPS). Everything stored is sealed.
• Tip: the haven-relay binary needs NONE of this — no ports, no public host.
  Re-run without --bucket to use it instead.
═══════════════════════════════════════════════════════════════
EOF
}

case "$MODE" in
  relay)  install_relay ;;
  bucket) start_bucket ;;
esac
