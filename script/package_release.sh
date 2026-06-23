#!/usr/bin/env bash
set -euo pipefail

# This script is the single source of truth for the bundle metadata
# written into dist/Apple Pi.app/Contents/Info.plist. The plist body
# itself lives in script/Info.plist.tpl so the file is diffable and
# reviewable in pull requests. This script only substitutes the
# placeholder tokens, runs plutil -lint, signs, and zips.

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
  # The `\&` in the replacement text is required: an unescaped `&`
  # inside `${var//pat/repl}` is treated as a job-control reference
  # by bash, so the literal `&amp;` we want to insert gets eaten.
  value="${value//&/\&amp;}"
  value="${value//</\&lt;}"
  value="${value//>/\&gt;}"
  printf '%s' "${value}"
}

# Escape a value for insertion into a bash `${var//pat/repl}` replacement.
# `&` and `\` are special in the replacement text, so they have to be
# doubled before the parameter expansion runs. Used below when we
# render `script/Info.plist.tpl` into `dist/Apple Pi.app/Contents/Info.plist`.
plist_subst_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
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
INFO_PLIST_TEMPLATE="${ROOT_DIR}/script/Info.plist.tpl"
ICON_SOURCE="${ROOT_DIR}/Sources/ApplePi/Resources/AppIcon.icns"
NOTIFY_EXTENSION_SOURCE="${ROOT_DIR}/Sources/ApplePi/Resources/ApplePiNotifyExtension.mjs"
APP_ENTITLEMENTS_SOURCE="${ROOT_DIR}/script/ApplePi.entitlements"
ZIP_PATH="${ROOT_DIR}/${DIST_DIR}/${ARCHIVE_NAME}-${VERSION}-${BUILD_NUMBER}.zip"
APP_NAME_PLIST="$(plist_escape "${APP_NAME}")"
BUNDLE_IDENTIFIER_PLIST="$(plist_escape "${BUNDLE_IDENTIFIER}")"
EXECUTABLE_NAME_PLIST="$(plist_escape "${EXECUTABLE_NAME}")"
VERSION_PLIST="$(plist_escape "${VERSION}")"
BUILD_NUMBER_PLIST="$(plist_escape "${BUILD_NUMBER}")"

APP_NAME_SUBST="$(plist_subst_escape "${APP_NAME_PLIST}")"
BUNDLE_IDENTIFIER_SUBST="$(plist_subst_escape "${BUNDLE_IDENTIFIER_PLIST}")"
EXECUTABLE_NAME_SUBST="$(plist_subst_escape "${EXECUTABLE_NAME_PLIST}")"
VERSION_SUBST="$(plist_subst_escape "${VERSION_PLIST}")"
BUILD_NUMBER_SUBST="$(plist_subst_escape "${BUILD_NUMBER_PLIST}")"

cd "${ROOT_DIR}"

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "Missing app icon at ${ICON_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${NOTIFY_EXTENSION_SOURCE}" ]]; then
  echo "Missing notification extension at ${NOTIFY_EXTENSION_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${APP_ENTITLEMENTS_SOURCE}" ]]; then
  echo "Missing entitlements file at ${APP_ENTITLEMENTS_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${INFO_PLIST_TEMPLATE}" ]]; then
  echo "Missing Info.plist template at ${INFO_PLIST_TEMPLATE}" >&2
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

# Render the Info.plist from script/Info.plist.tpl. The placeholders
# are `__APP_NAME__`, `__BUNDLE_IDENTIFIER__`, `__EXECUTABLE_NAME__`,
# `__VERSION__`, and `__BUILD_NUMBER__`. Substitution is done with
# bash parameter expansion so the values (which `plist_escape` has
# already escaped for XML, and `plist_subst_escape` has escaped for
# the bash pattern engine) are inserted verbatim — a `&` in the
# bundle name (or any other value) does not get interpreted as a
# pattern metacharacter and does not change which placeholder gets
# replaced. The template is ~3 KB, so reading it into a shell
# variable is cheap. `plutil -lint` below rejects the result if the
# template is malformed.
plutil_template="$(cat "${INFO_PLIST_TEMPLATE}")"
plutil_template="${plutil_template//__APP_NAME__/${APP_NAME_SUBST}}"
plutil_template="${plutil_template//__BUNDLE_IDENTIFIER__/${BUNDLE_IDENTIFIER_SUBST}}"
plutil_template="${plutil_template//__EXECUTABLE_NAME__/${EXECUTABLE_NAME_SUBST}}"
plutil_template="${plutil_template//__VERSION__/${VERSION_SUBST}}"
plutil_template="${plutil_template//__BUILD_NUMBER__/${BUILD_NUMBER_SUBST}}"
printf '%s' "${plutil_template}" > "${INFO_PLIST}"

printf "APPL????" > "${CONTENTS_DIR}/PkgInfo"

/usr/bin/plutil -lint "${INFO_PLIST}" >/dev/null
/usr/bin/xattr -cr "${BUNDLE_DIR}" 2>/dev/null || true
/usr/bin/codesign --force --sign "${SIGN_IDENTITY}" "${RESOURCES_DIR}/ApplePiAskpass"
/usr/bin/codesign --force --deep --options runtime --entitlements "${APP_ENTITLEMENTS_SOURCE}" --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"
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
