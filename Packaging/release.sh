#!/bin/zsh
# Prepare locally by default. --publish explicitly authorizes Git/GitHub writes.
set -euo pipefail
cd "$(dirname "$0")/.."
publish=false
if [[ ${1:-} == --publish ]]; then publish=true; shift; fi
if (( $# != 2 )); then
  print -u2 'Usage: Packaging/release.sh [--publish] VERSION "Markdown or HTML notes"'
  exit 2
fi
version=$1
notes=$2
[[ $version =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { print -u2 'Expected version X.Y or X.Y.Z'; exit 2; }
key="$HOME/.config/mdown/sparkle_ed25519_private.key"
[[ -r $key ]] || { print -u2 "Signing key unavailable: $key"; exit 1; }
command -v xmllint >/dev/null
command -v cmark >/dev/null || { print -u2 'Install cmark first: brew install cmark'; exit 1; }
# Check publication prerequisites before changing the working tree.
if $publish; then
  command -v gh >/dev/null
  [[ -z $(git status --porcelain) ]] || { print -u2 'Publishing requires a clean working tree.'; exit 1; }
  git pull --rebase
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/mdown-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
print -r -- "$notes" > "$work/notes.md"
# cmark converts Markdown to HTML and passes embedded HTML through.
cmark --unsafe "$work/notes.md" > "$work/notes.html"
build_number=$(python3 - "$version" <<'PY'
import pathlib, re, sys
p=pathlib.Path('MDown.xcodeproj/project.pbxproj')
s=p.read_text()
versions=re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', s)
if not versions or len(set(versions)) != 1: raise SystemExit('Inconsistent build numbers')
n=int(versions[0])+1
s=re.sub(r'CURRENT_PROJECT_VERSION = \d+;', f'CURRENT_PROJECT_VERSION = {n};', s)
s=re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {sys.argv[1]};', s)
p.write_text(s)
print(n)
PY
)
Packaging/make-dmg.sh
signer="${DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/mdown-release-build}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
dmg="${DMG_OUTPUT:-$PWD/build/MDown.dmg}"
"$signer" --ed-key-file "$key" -p "$dmg" > "$work/signature"
"$signer" --verify --ed-key-file "$key" "$dmg" "$(cat "$work/signature")"
python3 - "$version" "$build_number" "$dmg" "$work" <<'PY'
from xml.dom import minidom
from pathlib import Path
from email.utils import formatdate
import sys
v,b,dmg,work=sys.argv[1:]
w=Path(work); p=Path('docs/appcast.xml'); doc=minidom.parse(str(p))
channel=doc.getElementsByTagName('channel')[0]
if any(n.firstChild and n.firstChild.nodeValue==b for n in doc.getElementsByTagName('sparkle:version')):
    raise SystemExit('Build already in appcast')
item=doc.createElement('item')
def node(name,text):
    e=doc.createElement(name); e.appendChild(doc.createTextNode(text)); item.appendChild(e)
node('title','MDown '+v); node('pubDate',formatdate(usegmt=True))
node('sparkle:version',b); node('sparkle:shortVersionString',v)
node('sparkle:minimumSystemVersion','26.0')
e=doc.createElement('description')
# Multiple CDATA nodes safely encode even notes containing a CDATA terminator.
parts=(w/'notes.html').read_text().split(']]>')
for i,part in enumerate(parts):
    if i: e.appendChild(doc.createTextNode(']]>'))
    e.appendChild(doc.createCDATASection(part))
item.appendChild(e)
e=doc.createElement('enclosure')
for k,val in {'url':f'https://github.com/sandeepgangarapu/mdown/releases/download/v{v}/MDown.dmg','length':str(Path(dmg).stat().st_size),'type':'application/octet-stream','sparkle:edSignature':(w/'signature').read_text().strip()}.items(): e.setAttribute(k,val)
item.appendChild(e)
channel.insertBefore(item,channel.firstChild)
p.write_text(doc.toxml()+'\n')
PY
xmllint --noout docs/appcast.xml
# Keep the version in the website's structured data current.
sed -i '' -E "s/\"softwareVersion\": \"[^\"]*\"/\"softwareVersion\": \"$version\"/" docs/index.html
if $publish; then
  git add MDown.xcodeproj/project.pbxproj docs/appcast.xml docs/index.html
  git commit -m "Release MDown $version"
  git pull --rebase
  git push
  gh release create "v$version" "$dmg#MDown.dmg" --title "MDown $version" --notes-file "$work/notes.md"
  # Point the Homebrew cask (github.com/sandeepgangarapu/homebrew-tap) at the new DMG.
  sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
  gh repo clone sandeepgangarapu/homebrew-tap "$work/tap" -- --quiet
  sed -i '' -E "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$work/tap/Casks/mdown.rb"
  git -C "$work/tap" commit -qam "MDown $version"
  git -C "$work/tap" push -q
fi
print "Prepared MDown $version ($build_number): $dmg"
