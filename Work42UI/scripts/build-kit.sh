#!/bin/zsh
# Rebuild the precompiled kit stylesheet: Sources/Work42UI/Resources/kit/w42-kit-full.css
#
# w42-kit-full.css = Tailwind + Preline theme + Work42 theme + wk-* recipes, compiled against
# kit/safelist.html (+ kit/w42-gallery.html when present). It is used by markdown documents
# (file://, no per-document compile) and as the fallback when the per-artifact compile fails.
#
# Tailwind binary: $WORK42_TAILWIND, else ../work42/app/Vendor/tailwindcss/tailwindcss
# (fetch it with work42/app/scripts/fetch-tailwind.sh), else `tailwindcss` on PATH.
set -euo pipefail

here="${0:A:h}"
kit="$here/../Sources/Work42UI/Resources/kit"

tw="${WORK42_TAILWIND:-}"
[[ -z "$tw" && -x "$here/../../../work42/app/Vendor/tailwindcss/tailwindcss" ]] && tw="$here/../../../work42/app/Vendor/tailwindcss/tailwindcss"
[[ -z "$tw" ]] && tw="$(command -v tailwindcss || true)"
if [[ -z "$tw" || ! -x "$tw" ]]; then
  echo "error: Tailwind CLI not found. Run work42/app/scripts/fetch-tailwind.sh or set WORK42_TAILWIND." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
{
  echo '@import "tailwindcss" source(none);'
  echo "@source \"$kit/safelist.html\";"
  [[ -f "$kit/w42-gallery.html" ]] && echo "@source \"$kit/w42-gallery.html\";"
  echo "@import \"$kit/w42-kit.css\";"
} > "$work/input.css"

"$tw" -i "$work/input.css" -o "$kit/w42-kit-full.css" --minify
echo "wrote $kit/w42-kit-full.css ($(wc -c < "$kit/w42-kit-full.css") bytes)"
