#!/usr/bin/env sh
# Kith Bridge — one-command setup to host your circle's always-on mailbox.
#
# A "bridge" is just an S3-compatible bucket your circle shares. Every post is stored
# SEALED (the bridge can't read it) and re-served to anyone who's offline, so messages
# arrive even when the sender and receiver are never online at the same time.
#
# This self-hosts that bucket with `rclone serve s3` (rclone is MIT-licensed, a single
# cross-platform binary). It serves a plain folder over the S3 API — and because rclone
# can serve ANY of its 70+ backends, you can later point it at your own cloud drive,
# another S3, SFTP, etc. Prefer a managed bucket (S3 / R2 / B2)? You don't need this
# script — see README.md.
#
# Usage:   curl -fsSL https://wemiller.com/apps/haven/bridge/install.sh | sh
#   or:    sh install.sh [--native] [--port 8333] [--dir ~/kith-bridge]
set -eu

PORT=8333
DATADIR="${KITH_BRIDGE_DIR:-$HOME/kith-bridge}"
MODE=docker
BUCKET=kith

while [ $# -gt 0 ]; do
  case "$1" in
    --native) MODE=native ;;
    --port) PORT="$2"; shift ;;
    --dir) DATADIR="$2"; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
  shift
done

OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
mkdir -p "$DATADIR/data/$BUCKET"   # the folder named '$BUCKET' IS the S3 bucket

# Stable random credentials, generated once and saved (so re-runs don't change them).
CREDFILE="$DATADIR/.kith-bridge-creds"
if [ -f "$CREDFILE" ]; then
  . "$CREDFILE"
else
  AKEY="kith$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  SKEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf 'AKEY=%s\nSKEY=%s\n' "$AKEY" "$SKEY" > "$CREDFILE"
  chmod 600 "$CREDFILE"
fi

echo "▸ Kith Bridge (rclone serve s3 — MIT)  OS=$OS ARCH=$ARCH mode=$MODE"
echo "▸ Data dir: $DATADIR"

start_docker() {
  command -v docker >/dev/null 2>&1 || { echo "✗ Docker not found. Install it, or re-run with --native."; exit 1; }
  docker rm -f kith-bridge >/dev/null 2>&1 || true
  docker run -d --name kith-bridge --restart unless-stopped \
    -p "$PORT:8333" \
    -v "$DATADIR/data:/data" \
    rclone/rclone serve s3 /data --addr :8333 --auth-key "$AKEY,$SKEY" >/dev/null
  echo "✓ rclone serve s3 running in Docker (container: kith-bridge, auto-restarts)."
}

start_native() {
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
  echo "  For always-on, see README.md (systemd / launchd snippets)."
}

[ "$MODE" = docker ] && start_docker || start_native

LANIP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 127.0.0.1)"

cat <<EOF

═══════════════════════════════════════════════════════════════
✓ Your Kith bridge is live (rclone serve s3 — MIT, fully open source).

Paste these into Kith → You → Advanced → Storage → Custom S3 bucket,
then turn on "Volunteer as tribute":

   Endpoint:    $LANIP:$PORT
   Region:      us-east-1
   Bucket:      $BUCKET
   Access key:  $AKEY
   Secret key:  $SKEY

• Reachable on your network at  http://$LANIP:$PORT
• For your circle to reach it from anywhere, expose the port (router
  port-forward, Tailscale, or a small VPS). Everything stored is sealed —
  the bridge never sees your messages.
• rclone can serve other backends too (your cloud drive, another S3, SFTP):
  rclone serve s3 myremote:path --addr :$PORT --auth-key "KEY,SECRET"
═══════════════════════════════════════════════════════════════
EOF
