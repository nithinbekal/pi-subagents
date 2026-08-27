#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PUBLIC=("$ROOT/extensions" "$ROOT/skills" "$ROOT/docs" "$ROOT/package.json" "$ROOT/protocol.json" "$ROOT/README.md")

if grep -REni \
	'shopify|git@|/Users/|BEGIN (RSA |OPENSSH )?PRIVATE KEY|Bearer[[:space:]]+[A-Za-z0-9._~+/-]{16,}|api[_-]?key[[:space:]]*[:=][[:space:]]*[^$<{]' \
	"${PUBLIC[@]}"; then
	echo "public-safety check found a company reference, local absolute path, or credential-like literal" >&2
	exit 1
fi

if grep -REni '(^|[^A-Za-z])(researcher|implementer|reviewer|planner)([^A-Za-z]|$)' "${PUBLIC[@]}"; then
	echo "public-safety check found a role-specific worker prompt" >&2
	exit 1
fi

GENERATED_STATE=$(find "$ROOT" -path "$ROOT/.git" -prune -o \
	\( -name '.schema.json' -o -name '.watcher-pending' -o -name '.watcher-delivered' -o -name 'lifecycle.json' -o -name 'result.md' \) -print -quit)
if [ -n "$GENERATED_STATE" ]; then
	echo "public-safety check found generated worker state in the checkout: $GENERATED_STATE" >&2
	exit 1
fi

echo "public safety: ok"
