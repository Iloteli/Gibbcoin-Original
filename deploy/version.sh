#!/usr/bin/env bash
# Gibt die installierte Version aus, z. B. "1.6.0 (Build 412 · 18.10.2026)".
#   gibb-version
APP_DIR="${APP_DIR:-/opt/gibbcoin}"
cd "$APP_DIR" 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")/.."
VER="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
BUILD="$(git -c safe.directory='*' rev-list --count HEAD 2>/dev/null || echo "?")"
DATE="$(git -c safe.directory='*' log -1 --format=%cd --date=format:%d.%m.%Y 2>/dev/null || echo "?")"
echo "${VER:-?} (Build $BUILD · $DATE)"
