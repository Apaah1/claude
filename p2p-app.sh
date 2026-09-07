#!/usr/bin/env bash
#
# p2p-app.sh — dev / test / build / deploy helper for the P2P chat app
# (single-file WebRTC/PeerJS app with AES-GCM + PBKDF2 rooms)
#
# Usage:
#   ./p2p-app.sh dev        # local dev server with auto-reload
#   ./p2p-app.sh test       # HTML validity + JS lint checks
#   ./p2p-app.sh build      # produce a packaged/minified output
#   ./p2p-app.sh deploy     # deploy the build to a static host
#   ./p2p-app.sh all        # test -> build -> dev (deploy skipped unless -d)
#
# Options:
#   -f <file>   path to the app's HTML file (default: $APP_FILE or index.html)
#   -p <port>   dev server port (default: 8080)
#   -d          when used with "all", also run deploy at the end
#
# Env vars:
#   APP_FILE     override default HTML entry file
#   DEPLOY_TARGET  "gh-pages" | "surge" | "netlify" (default: gh-pages)

set -euo pipefail

APP_FILE="${APP_FILE:-index.html}"
PORT=8080
RUN_DEPLOY=false
DEPLOY_TARGET="${DEPLOY_TARGET:-gh-pages}"
DIST_DIR="dist"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

while getopts "f:p:d" opt; do
  case "$opt" in
    f) APP_FILE="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    d) RUN_DEPLOY=true ;;
    *) fail "unknown option" ;;
  esac
done
shift $((OPTIND - 1))

CMD="${1:-}"
[ -z "$CMD" ] && fail "usage: $0 [-f file] [-p port] [-d] {dev|test|build|deploy|all}"

[ -f "$APP_FILE" ] || fail "app file '$APP_FILE' not found. Use -f to point at it or set APP_FILE."

require_node() {
  command -v node >/dev/null 2>&1 || fail "Node.js is required. Install it, then re-run."
  command -v npx  >/dev/null 2>&1 || fail "npx (comes with npm) is required."
}

do_install() {
  log "Checking toolchain"
  require_node
  log "No package.json deps needed (single-file app) — dev tools installed on demand via npx"
}

do_dev() {
  log "Starting dev server on http://localhost:$PORT with auto-reload"
  require_node
  npx --yes live-server --port="$PORT" --entry-file="$APP_FILE" .
}

do_test() {
  log "Validating HTML: $APP_FILE"
  require_node
  npx --yes html-validate "$APP_FILE" || fail "HTML validation failed"

  log "Extracting and lint-checking inline <script> blocks"
  TMP_JS="$(mktemp).js"
  # Pull out inline script content (skips scripts with an external src=)
  node -e "
    const fs = require('fs');
    const html = fs.readFileSync('$APP_FILE', 'utf8');
    const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
    let m, out = '';
    while ((m = re.exec(html))) out += m[1] + '\n';
    fs.writeFileSync('$TMP_JS', out);
  "
  npx --yes eslint --no-eslintrc --env browser,es2021 --parser-options=ecmaVersion:2021 "$TMP_JS" \
    || echo "Lint found issues above (non-fatal) — review before shipping."
  rm -f "$TMP_JS"

  log "Basic checks passed"
}

do_build() {
  log "Packaging $APP_FILE into $DIST_DIR/"
  require_node
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"

  npx --yes html-minifier-terser \
    --collapse-whitespace --remove-comments --minify-css true --minify-js true \
    -o "$DIST_DIR/index.html" "$APP_FILE" \
    || cp "$APP_FILE" "$DIST_DIR/index.html"  # fallback: copy unminified if minifier fails

  # PWA assets referenced by index.html (manifest, service worker, icons)
  # ship as-is alongside it so the packaged build is installable too.
  [ -f manifest.json ] && cp manifest.json "$DIST_DIR/"
  [ -f sw.js ] && cp sw.js "$DIST_DIR/"
  [ -d icons ] && cp -r icons "$DIST_DIR/"

  ( cd "$DIST_DIR" && zip -q -r "../p2p-app-build.zip" . )
  log "Build ready: $DIST_DIR/index.html and p2p-app-build.zip"
}

do_deploy() {
  [ -d "$DIST_DIR" ] || do_build
  log "Deploying $DIST_DIR/ via $DEPLOY_TARGET"
  require_node
  case "$DEPLOY_TARGET" in
    gh-pages)
      npx --yes gh-pages -d "$DIST_DIR" \
        || fail "gh-pages deploy failed — must be run inside a git repo with a remote set"
      ;;
    surge)
      npx --yes surge "$DIST_DIR" || fail "surge deploy failed"
      ;;
    netlify)
      npx --yes netlify-cli deploy --dir="$DIST_DIR" --prod || fail "netlify deploy failed"
      ;;
    *)
      fail "unknown DEPLOY_TARGET: $DEPLOY_TARGET (use gh-pages|surge|netlify)"
      ;;
  esac
  log "Deploy complete"
}

case "$CMD" in
  dev)    do_install; do_dev ;;
  test)   do_install; do_test ;;
  build)  do_install; do_build ;;
  deploy) do_install; do_deploy ;;
  all)
    do_install
    do_test
    do_build
    if $RUN_DEPLOY; then do_deploy; fi
    do_dev
    ;;
  *) fail "unknown command '$CMD' — expected dev|test|build|deploy|all" ;;
esac
