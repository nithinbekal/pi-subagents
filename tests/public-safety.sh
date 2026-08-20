#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if grep -REni 'shopify|git@|api[_-]?key[[:space:]]*[:=][[:space:]]*[^$<{]' \
	"$ROOT/extensions" "$ROOT/skills" "$ROOT/package.json" "$ROOT/README.md"; then
	echo "public-safety check found a company reference or credential-like literal" >&2
	exit 1
fi

echo "public safety: ok"
