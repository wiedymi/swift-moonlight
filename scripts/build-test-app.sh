#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_SPEC="${ROOT_DIR}/project.yml"
PROJECT_PATH="${ROOT_DIR}/SwiftMoonlightApps.xcodeproj"
SCHEME="SwiftMoonlightTestApp"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${ROOT_DIR}/.build/xcode/DerivedData"
APP_ICON_DIR="${ROOT_DIR}/AppResources/SwiftMoonlightTestApp/Assets.xcassets/AppIcon.appiconset"
OPEN_APP=1
OPEN_PROJECT=0
PROJECT_ONLY=0

usage() {
    cat <<'EOF'
Usage: ./scripts/build-test-app.sh [options]

Options:
  --configuration <Debug|Release>  Xcode build configuration. Default: Debug
  --build-only                     Build the app bundle but do not open it.
  --project-only                   Generate the Xcode project and stop.
  --open-project                   Generate the Xcode project and open it in Xcode.
  --help                           Show this help text.
EOF
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required tool: $1" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --build-only)
            OPEN_APP=0
            shift
            ;;
        --project-only)
            PROJECT_ONLY=1
            OPEN_APP=0
            shift
            ;;
        --open-project)
            OPEN_PROJECT=1
            OPEN_APP=0
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "${CONFIGURATION}" in
    Debug|Release) ;;
    *)
        echo "Unsupported configuration: ${CONFIGURATION}" >&2
        exit 1
        ;;
esac

require_tool swift
require_tool xcodegen
require_tool xcodebuild
require_tool open
require_tool osascript

swift "${ROOT_DIR}/scripts/generate-test-app-icon.swift" "${APP_ICON_DIR}"
xcodegen generate --spec "${PROJECT_SPEC}"

if [[ ${PROJECT_ONLY} -eq 1 ]]; then
    echo "Generated ${PROJECT_PATH}"
    exit 0
fi

if [[ ${OPEN_PROJECT} -eq 1 ]]; then
    open "${PROJECT_PATH}"
    exit 0
fi

xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -destination "platform=macOS" \
    CODE_SIGNING_ALLOWED=NO \
    build

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/Swift Moonlight Test App.app"

if [[ ! -d "${APP_PATH}" ]]; then
    echo "Built app bundle not found at ${APP_PATH}" >&2
    exit 1
fi

echo "Built app bundle at ${APP_PATH}"

if [[ ${OPEN_APP} -eq 1 ]]; then
    osascript <<'EOF' >/dev/null 2>&1 || true
tell application id "dev.vivy.swift-moonlight.test-app"
    if it is running then
        quit
    end if
end tell
EOF
    open -n "${APP_PATH}"
fi
