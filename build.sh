#!/bin/bash
set -e

swift build -c release

BINARY=".build/release/swm"
DEST="$HOME/bin/swm"

echo "Build complete: $BINARY"
cp "$BINARY" "$DEST"
echo "Installed to $DEST"
