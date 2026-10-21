#!/bin/zsh
# Rebuilds Sources/Web/vendor/novnc-<version>.js: noVNC's core, unmodified, bundled into one minified
# ES module (with pako). Needs Node; build.sh does not, it only embeds the result.
set -euo pipefail
VERSION=${1:-1.7.0}
cd "${0:A:h}/.."
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
(cd $T && npm pack "@novnc/novnc@$VERSION" --silent >/dev/null && tar xzf novnc-novnc-$VERSION.tgz)
(cd $T && npm init -y >/dev/null && npm install --silent esbuild@0.25.0)
P=$T/package
cat > $T/entry.js <<JS
export { default as RFB } from "$P/core/rfb.js";
export { default as KeyTable } from "$P/core/input/keysym.js";
export { default as keysyms } from "$P/core/input/keysymdef.js";
JS
$T/node_modules/.bin/esbuild $T/entry.js --bundle --minify --format=esm --target=safari16 --legal-comments=none --outfile=$T/out.js
{ printf '/*! noVNC %s core (https://github.com/novnc/noVNC), MPL-2.0, with pako (MIT). Bundled by tools/vendor-novnc.sh; see Sources/Web/vendor/NOVNC-LICENSE.txt. */\n' $VERSION; cat $T/out.js; } > Sources/Web/vendor/novnc-$VERSION.js
{ echo "noVNC $VERSION — https://github.com/novnc/noVNC"
  echo "The noVNC core is licensed under the Mozilla Public License 2.0; its source is unmodified and available at the link above."
  echo; cat $P/LICENSE.txt; echo; echo "----- pako (vendor/pako) -----"; cat $P/vendor/pako/LICENSE
  echo; echo "----- Mozilla Public License 2.0 -----"; cat $P/docs/LICENSE.MPL-2.0; } > Sources/Web/vendor/NOVNC-LICENSE.txt
echo "Sources/Web/vendor/novnc-$VERSION.js: $(wc -c < Sources/Web/vendor/novnc-$VERSION.js) bytes"
