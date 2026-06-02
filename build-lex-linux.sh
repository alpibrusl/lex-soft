#!/usr/bin/env bash
# build-lex-linux.sh — compile a Linux lex binary using Docker.
#
# Run this once from lex-soft/, or whenever lex-lang/ changes.
# Outputs: ../lex-lang/target/linux/lex
#
# Usage: ./build-lex-linux.sh

set -euo pipefail

WORKSPACE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$WORKSPACE/lex-lang/target/linux"

echo "Building lex for Linux (this takes ~10 min the first time, cached after)..."

docker build \
  --file "$WORKSPACE/lex-soft/Dockerfile.lex-builder" \
  --output "type=local,dest=$OUT" \
  "$WORKSPACE"

echo "Binary ready at lex-lang/target/linux/lex"
