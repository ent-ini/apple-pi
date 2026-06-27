#!/usr/bin/env bash
set -euo pipefail

# Build and install pi-app as a normal macOS application.
# Defaults:
#   /Applications/pi-app.app
#   ad-hoc signing identity (-)
#
# Examples:
#   script/install_app.sh
#   OPEN_AFTER_INSTALL=1 script/install_app.sh
#   DEST_DIR="$HOME/Applications" script/install_app.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-pi-app}"
DEST_DIR="${DEST_DIR:-/Applications}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"
BUNDLE_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
DEST_APP="${DEST_DIR}/${APP_NAME}.app"

cd "${ROOT_DIR}"

APP_NAME="${APP_NAME}" \
ARCHIVE_NAME="${ARCHIVE_NAME:-pi-app}" \
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.entini.piapp}" \
EXECUTABLE_NAME="${EXECUTABLE_NAME:-pi-app}" \
script/package_release.sh --no-zip

# Quit the installed app if it is currently running. Ignore failures: first
# install, renamed bundle, or ad-hoc signing can all make osascript return
# non-zero even though it is safe to continue.
/usr/bin/osascript -e "tell application id \"${BUNDLE_IDENTIFIER:-com.entini.piapp}\" to quit" >/dev/null 2>&1 || true
pkill -x "${EXECUTABLE_NAME:-pi-app}" >/dev/null 2>&1 || true
sleep 0.4

mkdir -p "${DEST_DIR}"
rm -rf "${DEST_APP}"
/usr/bin/ditto "${BUNDLE_DIR}" "${DEST_APP}"
/usr/bin/xattr -dr com.apple.quarantine "${DEST_APP}" 2>/dev/null || true

/usr/bin/codesign --verify --deep --strict --verbose=2 "${DEST_APP}"

if [[ "${OPEN_AFTER_INSTALL}" == "1" ]]; then
  /usr/bin/open "${DEST_APP}"
fi

echo "Installed ${DEST_APP}"
