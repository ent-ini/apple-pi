#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Apple Pi}"
ARCHIVE_NAME="${ARCHIVE_NAME:-apple-pi}"
PRODUCT_NAME="${PRODUCT_NAME:-ApplePi}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.dodoreach.ApplePi}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-ApplePi}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-dist}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

RUN_AFTER_BUILD=0
VERIFY_LAUNCH=0
CREATE_ZIP=1

usage() {
  cat <<USAGE
Usage: script/package_release.sh [--run] [--verify] [--no-zip] [--sign-identity IDENTITY]

Environment:
  VERSION=0.1.0
  BUILD_NUMBER=<git commit count>
  ARCHIVE_NAME=apple-pi
  BUNDLE_IDENTIFIER=com.dodoreach.ApplePi
  SIGN_IDENTITY=-                  # ad-hoc local signing by default
USAGE
}

app_is_running() {
  if pgrep -x "${EXECUTABLE_NAME}" >/dev/null 2>&1; then
    return 0
  fi

  [[ "$(/usr/bin/osascript -e "tell application \"System Events\" to exists process \"${EXECUTABLE_NAME}\"" 2>/dev/null || true)" == "true" ]]
}

quit_running_app() {
  if app_is_running; then
    /usr/bin/osascript -e "tell application id \"${BUNDLE_IDENTIFIER}\" to quit" >/dev/null 2>&1 || \
      pkill -x "${EXECUTABLE_NAME}" >/dev/null 2>&1 || true
    sleep 0.4
  fi
}

plist_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "${value}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      RUN_AFTER_BUILD=1
      ;;
    --verify)
      RUN_AFTER_BUILD=1
      VERIFY_LAUNCH=1
      ;;
    --no-zip)
      CREATE_ZIP=0
      ;;
    --sign-identity)
      if [[ $# -lt 2 ]]; then
        echo "--sign-identity requires a value" >&2
        exit 2
      fi
      SIGN_IDENTITY="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "${BUILD_NUMBER}" ]]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="${ROOT_DIR}/${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
EXECUTABLE_PATH="${MACOS_DIR}/${EXECUTABLE_NAME}"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
ICON_SOURCE="${ROOT_DIR}/Sources/ApplePi/Resources/AppIcon.icns"
NOTIFY_EXTENSION_SOURCE="${ROOT_DIR}/Sources/ApplePi/Resources/ApplePiNotifyExtension.mjs"
ZIP_PATH="${ROOT_DIR}/${DIST_DIR}/${ARCHIVE_NAME}-${VERSION}-${BUILD_NUMBER}.zip"
APP_NAME_PLIST="$(plist_escape "${APP_NAME}")"
BUNDLE_IDENTIFIER_PLIST="$(plist_escape "${BUNDLE_IDENTIFIER}")"
EXECUTABLE_NAME_PLIST="$(plist_escape "${EXECUTABLE_NAME}")"
VERSION_PLIST="$(plist_escape "${VERSION}")"
BUILD_NUMBER_PLIST="$(plist_escape "${BUILD_NUMBER}")"

cd "${ROOT_DIR}"

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "Missing app icon at ${ICON_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${NOTIFY_EXTENSION_SOURCE}" ]]; then
  echo "Missing notification extension at ${NOTIFY_EXTENSION_SOURCE}" >&2
  exit 1
fi

swift build -c "${CONFIGURATION}" --product "${PRODUCT_NAME}"
swift build -c "${CONFIGURATION}" --product "ApplePiAskpass"

rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp ".build/${CONFIGURATION}/${PRODUCT_NAME}" "${EXECUTABLE_PATH}"
cp ".build/${CONFIGURATION}/ApplePiAskpass" "${RESOURCES_DIR}/ApplePiAskpass"
cp "${ICON_SOURCE}" "${RESOURCES_DIR}/AppIcon.icns"
cp "${NOTIFY_EXTENSION_SOURCE}" "${RESOURCES_DIR}/ApplePiNotifyExtension.mjs"
chmod +x "${EXECUTABLE_PATH}" "${RESOURCES_DIR}/ApplePiAskpass"

cat > "${INFO_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME_PLIST}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME_PLIST}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_IDENTIFIER_PLIST}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME_PLIST}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION_PLIST}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER_PLIST}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Apple Pi launches terminal sessions in project folders you choose, including projects on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Apple Pi launches terminal sessions in project folders you choose, including projects in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Apple Pi launches terminal sessions in project folders you choose, including projects in Downloads.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 dodo-reach. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

printf "APPL????" > "${CONTENTS_DIR}/PkgInfo"

/usr/bin/plutil -lint "${INFO_PLIST}" >/dev/null
/usr/bin/xattr -cr "${BUNDLE_DIR}" 2>/dev/null || true
/usr/bin/codesign --force --sign "${SIGN_IDENTITY}" "${RESOURCES_DIR}/ApplePiAskpass"
/usr/bin/codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"

if [[ "${CREATE_ZIP}" -eq 1 ]]; then
  /usr/bin/ditto -c -k --norsrc --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"
fi

echo "Built ${BUNDLE_DIR}"
if [[ "${CREATE_ZIP}" -eq 1 ]]; then
  echo "Archived ${ZIP_PATH}"
fi
echo "Version ${VERSION} (${BUILD_NUMBER})"
echo "Bundle identifier ${BUNDLE_IDENTIFIER}"
echo "Signing identity ${SIGN_IDENTITY}"

if [[ "${RUN_AFTER_BUILD}" -eq 1 ]]; then
  quit_running_app

  /usr/bin/open -n "${BUNDLE_DIR}"

  if [[ "${VERIFY_LAUNCH}" -eq 1 ]]; then
    for _ in {1..30}; do
      if app_is_running; then
        echo "${APP_NAME} launched"
        exit 0
      fi
      sleep 0.25
    done

    echo "${APP_NAME} did not appear in the process list" >&2
    exit 1
  fi
fi
