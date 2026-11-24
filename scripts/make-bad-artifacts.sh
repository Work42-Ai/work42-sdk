#!/bin/bash
# make-bad-artifacts.sh — generate installer rejection fixtures (WOR-866).
#
#   scripts/make-bad-artifacts.sh <good-artifact.zip> <out-dir>
#
# macOS prerequisites: Python 3, ditto, codesign, security, openssl.
# WORK42_ALT_SIGN_IDENTITY optionally selects the wrong-team signing identity.
# Emits four emulator catalog JSON lines on stdout; diagnostics go to stderr.
# Temporary files, certificate trust and the throwaway keychain are removed at exit. Never publish
# these fixtures. SDK fixtures may fail Gatekeeper first if not re-notarized.

set -euo pipefail
export LC_ALL=C
die() { echo "make-bad-artifacts: $*" >&2; exit 2; }
[[ $# == 2 ]] || die "usage: make-bad-artifacts.sh <good-artifact.zip> <out-dir>; supply a published plugin zip."
[[ -f "$1" ]] || die "input is missing: $1; supply an existing published plugin zip."
for tool in python3 ditto codesign security openssl file; do
  command -v "$tool" >/dev/null || die "missing $tool; install the macOS command-line tools and Python 3."
done

good="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")"
# Validate paths before extraction (including symlink targets), and CRCs before
# modifying anything. A top-level directory entry itself is optional.
top="$(python3 - "$good" <<'PY'
import stat, sys, zipfile
def refuse(message):
    print("make-bad-artifacts: " + message +
          "; re-export one plugin folder with ditto -c -k --keepParent --norsrc --noextattr.", file=sys.stderr)
    sys.exit(2)
try:
    with zipfile.ZipFile(sys.argv[1]) as z:
        infos = z.infolist()
        roots = set()
        for i in infos:
            parts = i.filename.rstrip("/").split("/")
            if not parts or any(p in ("", ".", "..") for p in parts) or "\\" in i.filename:
                refuse("unsafe ZIP member path")
            if any(p.startswith("._") for p in parts):
                refuse("AppleDouble entries in input")
            roots.add(parts[0])
            if len(parts) == 1 and not i.is_dir():
                refuse("expected a top-level folder, not a file")
            if stat.S_ISLNK(i.external_attr >> 16):
                target = z.read(i).decode("utf-8")
                resolved = list(parts[:-1])
                if target.startswith("/"):
                    refuse("absolute symlink in input")
                for p in target.split("/"):
                    if p == "..":
                        if len(resolved) <= 1:
                            refuse("symlink escapes plugin folder")
                        resolved.pop()
                    elif p not in ("", "."):
                        resolved.append(p)
        if len(roots) != 1:
            refuse("expected exactly one top-level folder")
        root = next(iter(roots))
        if root + "/plugin.yaml" not in z.namelist():
            refuse("plugin.yaml is missing")
        if z.testzip() is not None:
            refuse("ZIP member failed CRC verification")
        print(root)
except (OSError, ValueError, UnicodeError, zipfile.BadZipFile, RuntimeError) as e:
    refuse("not a readable plugin zip: " + str(e))
PY
)" || exit 2

mkdir -p "$2"
out="$(cd "$2" && pwd)"
for variant in bad-hash unsigned wrong-team sdk-4; do
  [[ ! -e "$out/$variant.zip" ]] || die "$out/$variant.zip already exists; use an empty output directory."
done
work="$(mktemp -d /tmp/work42-bad-artifacts.XXXXXX)"
keychain=""
trusted_cert=""
cleanup() {
  if [[ -n "$trusted_cert" ]]; then security remove-trusted-cert "$trusted_cert" >&2 || true; fi
  if [[ -n "$keychain" ]]; then security delete-keychain "$keychain" >&2 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

extract() {
  rm -rf "$work/tree"
  mkdir "$work/tree"
  ditto -x -k --norsrc --noextattr "$good" "$work/tree" >&2
}
pack() {
  ditto -c -k --keepParent --norsrc --noextattr "$work/tree/$top" "$out/$1.zip" >&2
}
extract
machos=()
while IFS= read -r -d '' path; do
  if file -b "$path" | grep -q 'Mach-O'; then
    machos+=("${path#"$work/tree/"}")
  fi
done < <(find "$work/tree/$top" -type f -print0)
[[ ${#machos[@]} -gt 0 ]] || die "no Mach-O found; supply a compiled plugin artifact."
first="$work/tree/${machos[0]}"
details="$(codesign -dvv "$first" 2>&1)" || die "first Mach-O is unsigned; supply a signed artifact."
original_team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')"
original_team="${original_team:-not set}"
original_identity="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -1)"
security find-identity -v -p codesigning > "$work/identities"

# Probe actual signatures instead of assuming a certificate's display name is
# its Team ID. Use a copy so failed candidates never alter the fixture.
probe() {
  cp "$first" "$work/probe.dylib"
  codesign --force --sign "$1" --options runtime --timestamp=none "$work/probe.dylib" >"$work/probe.log" 2>&1 || return 1
  probe_details="$(codesign -dvv "$work/probe.dylib" 2>&1)"
  probe_team="$(printf '%s\n' "$probe_details" | sed -n 's/^TeamIdentifier=//p')"
  [[ "${probe_team:-not set}" != "$original_team" ]]
}
alt="${WORK42_ALT_SIGN_IDENTITY:-}"
alt_keychain=()
if [[ -n "$alt" ]]; then
  probe "$alt" || die "alternate identity cannot sign or has the original Team ID; choose a different WORK42_ALT_SIGN_IDENTITY."
else
  while IFS= read -r candidate; do
    if probe "$candidate"; then alt="$candidate"; break; fi
  done < <(sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]{40}) .*/\1/p' "$work/identities")
fi
if [[ -z "$alt" ]]; then
  echo "make-bad-artifacts: creating a temporary self-signed codesigning identity." >&2
  keychain="$work/qa.keychain-db"
  password="$(openssl rand -hex 24)"
  cat > "$work/cert.cnf" <<'CONF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Work42 Wrong Team QA
OU = WORK42QA00
[extensions]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
  openssl req -new -newkey rsa:2048 -nodes -x509 -days 1 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" >&2
  # Explicit legacy algorithms also work with the macOS PKCS#12 importer.
  openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -out "$work/identity.p12" -passout "pass:$password" >&2
  security create-keychain -p "$password" "$keychain" >&2
  security unlock-keychain -p "$password" "$keychain" >&2
  security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >&2
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >&2
  # Select by fingerprint: self-signed certificates are not in the valid
  # identity list, and codesign's name lookup can otherwise reject them.
  alt="$(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
  # macOS requires trust before codesign can resolve a self-signed identity.
  # Scope trust to code signing and remove this exact certificate on exit.
  echo "make-bad-artifacts: macOS may request authorization for temporary code-signing trust." >&2
  trusted_cert="$work/cert.pem"
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$trusted_cert" >&2
  alt_keychain=(--keychain "$keychain")
fi

# Change only the central-directory DOS modification-time byte. Unlike a
# payload flip this preserves decompression and CRCs, isolating the hash gate.
python3 - "$good" "$out/bad-hash.zip" "$work/good.sha256" <<'PY'
import hashlib, shutil, sys, zipfile
with open(sys.argv[1], "rb") as f:
    digest = hashlib.file_digest(f, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else None
    if digest is None:
        f.seek(0)
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
        digest = h.hexdigest()
with open(sys.argv[3], "w") as f:
    f.write(digest)
with zipfile.ZipFile(sys.argv[1]) as z:
    offset = z.start_dir + 12
shutil.copyfile(sys.argv[1], sys.argv[2])
with open(sys.argv[2], "r+b") as f:
    f.seek(offset)
    byte = f.read(1)
    f.seek(offset)
    f.write(bytes([byte[0] ^ 1]))
PY

for path in "${machos[@]}"; do codesign --remove-signature "$work/tree/$path" >&2; done
pack unsigned
extract
for path in "${machos[@]}"; do
  # Developer ID identities require a secure timestamp; local QA identities do not.
  timestamp=--timestamp=none
  cp "$work/tree/$path" "$work/probe.dylib"
  codesign --force --sign "$alt" ${alt_keychain[@]+"${alt_keychain[@]}"} --options runtime --timestamp=none "$work/probe.dylib" >&2
  signed_details="$(codesign -dvv "$work/probe.dylib" 2>&1)"
  if [[ "$signed_details" == *"Authority=Developer ID Application:"* ]]; then timestamp=--timestamp; fi
  codesign --force --sign "$alt" ${alt_keychain[@]+"${alt_keychain[@]}"} --options runtime "$timestamp" "$work/tree/$path" >&2
done
pack wrong-team
extract
python3 - "$work/tree/$top/plugin.yaml" <<'PY'
import re, sys
p = sys.argv[1]
with open(p, newline="") as f:
    text = f.read()
text, count = re.subn(r"^sdk_version:[^\r\n]*", "sdk_version: 4.0.0", text, flags=re.M)
if count != 1:
    sys.exit("make-bad-artifacts: expected one top-level sdk_version line; use a published manifest.")
with open(p, "w", newline="") as f:
    f.write(text)
PY
identity=-
if [[ -n "$original_identity" ]] && grep -Fq "\"$original_identity\"" "$work/identities"; then
  identity="$original_identity"
else
  echo "make-bad-artifacts: original signing identity unavailable; sdk-4 uses ad-hoc signing and may fail before the SDK gate." >&2
fi
timestamp=--timestamp=none
[[ "$identity" != "Developer ID Application:"* ]] || timestamp=--timestamp
for path in "${machos[@]}"; do
  codesign --force --sign "$identity" --options runtime "$timestamp" "$work/tree/$path" >&2
done
pack sdk-4

python3 - "$out" "$original_team" "$work/good.sha256" <<'PY'
import hashlib, json, os, sys
out, team, good_hash = sys.argv[1:]
for variant in ("bad-hash", "unsigned", "wrong-team", "sdk-4"):
    path = os.path.join(out, variant + ".zip")
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    with open(good_hash) as f:
        digest = f.read() if variant == "bad-hash" else h.hexdigest()
    print(json.dumps(dict(variant=variant, file=path, sha256=digest,
        size=os.path.getsize(path), teamId=team,
        sdkVersion="4.0.0" if variant == "sdk-4" else "3.2.0",
        runtime="inprocess", yanked=False), separators=(",", ":")))
PY
