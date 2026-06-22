#!/usr/bin/env bash
# Build the Rust core (`haven_ffi`) into HavenFFI.xcframework and regenerate the
# Swift bindings. Run this before `xcodegen generate` / opening the Xcode project.
#
# Requires rustup with the iOS targets (this script adds them if missing). It uses
# rustup's cargo explicitly via $CARGO so it never depends on your default toolchain.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/../core"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
RUSTUP="${RUSTUP:-$HOME/.cargo/bin/rustup}"

echo "▸ Ensuring Apple targets (iOS device + sim + Mac Catalyst)…"
"$RUSTUP" target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-ios-macabi >/dev/null

echo "▸ Building static libs (device + simulator + Mac Catalyst)…"
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-ios )
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-ios-sim )
( cd "$CORE" && "$CARGO" build -p haven_ffi --lib --release --target aarch64-apple-ios-macabi )

echo "▸ Generating Swift bindings…"
( cd "$CORE" && "$CARGO" build -q -p haven_ffi --lib )   # host dylib for the generator
rm -rf "$HERE/Generated"; mkdir -p "$HERE/Generated"
( cd "$CORE" && "$CARGO" run -q -p haven_ffi --bin uniffi-bindgen -- \
    generate --library target/debug/libhaven_ffi.dylib --language swift --out-dir "$HERE/Generated" )

echo "▸ Assembling HavenFFI.xcframework…"
rm -rf "$HERE/HavenFFI.xcframework" "$HERE/build/headers"
mkdir -p "$HERE/build/headers"
cp "$HERE/Generated/haven_ffiFFI.h" "$HERE/build/headers/"
cp "$HERE/Generated/haven_ffiFFI.modulemap" "$HERE/build/headers/module.modulemap"
xcodebuild -create-xcframework \
  -library "$CORE/target/aarch64-apple-ios/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$CORE/target/aarch64-apple-ios-sim/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -library "$CORE/target/aarch64-apple-ios-macabi/release/libhaven_ffi.a" -headers "$HERE/build/headers" \
  -output "$HERE/HavenFFI.xcframework" >/dev/null

echo "✓ Done. Next:  cd apple && xcodegen generate && open Kith.xcodeproj"
echo "  (device build: set your Team in Signing & Capabilities, then Run on your iPhone)"
