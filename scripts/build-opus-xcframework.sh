#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPUS_VERSION="${OPUS_VERSION:-1.6.1}"
OPUS_TAG="v${OPUS_VERSION}"
WORK_DIR="${ROOT_DIR}/.build/vendor-opus"
SOURCE_ARCHIVE="${WORK_DIR}/opus-${OPUS_VERSION}.tar.gz"
SOURCE_DIR="${WORK_DIR}/opus-${OPUS_VERSION}"
HEADERS_DIR="${WORK_DIR}/headers"
OUTPUT_DIR="${ROOT_DIR}/Vendor/COpus.xcframework"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required tool: $1" >&2
        exit 1
    fi
}

require_tool curl
require_tool tar
require_tool cmake
require_tool xcodebuild
require_tool xcrun
require_tool lipo

mkdir -p "${WORK_DIR}" "${ROOT_DIR}/Vendor"

if [[ ! -f "${SOURCE_ARCHIVE}" ]]; then
    curl -L "https://github.com/xiph/opus/archive/refs/tags/${OPUS_TAG}.tar.gz" -o "${SOURCE_ARCHIVE}"
fi

rm -rf "${SOURCE_DIR}"
tar -xzf "${SOURCE_ARCHIVE}" -C "${WORK_DIR}"

rm -rf "${HEADERS_DIR}"
mkdir -p "${HEADERS_DIR}/opus"
cp "${SOURCE_DIR}/include/"*.h "${HEADERS_DIR}/opus/"

cat > "${HEADERS_DIR}/shim.h" <<'EOF'
#include <opus/opus.h>
#include <opus/opus_multistream.h>
EOF

cat > "${HEADERS_DIR}/module.modulemap" <<'EOF'
module COpus [system] {
    header "shim.h"
    export *
}
EOF

build_opus() {
    local name="$1"
    local system_name="$2"
    local sysroot="$3"
    local arch="$4"
    local deployment_target="$5"

    local build_dir="${WORK_DIR}/build-${name}-${arch}"
    local install_dir="${WORK_DIR}/install-${name}-${arch}"

    rm -rf "${build_dir}" "${install_dir}"

    local -a cmake_args=(
        -S "${SOURCE_DIR}"
        -B "${build_dir}"
        -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="${install_dir}"
        -DCMAKE_OSX_SYSROOT="${sysroot}"
        -DCMAKE_OSX_ARCHITECTURES="${arch}"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}"
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
        -DBUILD_TESTING=OFF
        -DOPUS_BUILD_TESTING=OFF
        -DOPUS_BUILD_PROGRAMS=OFF
        -DOPUS_BUILD_SHARED_LIBRARY=OFF
        -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF
        -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
    )

    if [[ -n "${system_name}" ]]; then
        cmake_args+=(-DCMAKE_SYSTEM_NAME="${system_name}")
    fi

    cmake "${cmake_args[@]}"
    cmake --build "${build_dir}" --target install
}

lipo_combine() {
    local output="$1"
    shift
    rm -f "${output}"
    xcrun lipo -create "$@" -output "${output}"
}

build_opus "macos" "" "macosx" "arm64" "14.0"
build_opus "macos" "" "macosx" "x86_64" "14.0"
build_opus "ios" "iOS" "iphoneos" "arm64" "17.0"
build_opus "iossim" "iOS" "iphonesimulator" "arm64" "17.0"
build_opus "iossim" "iOS" "iphonesimulator" "x86_64" "17.0"
build_opus "tvos" "tvOS" "appletvos" "arm64" "17.0"
build_opus "tvossim" "tvOS" "appletvsimulator" "arm64" "17.0"
build_opus "tvossim" "tvOS" "appletvsimulator" "x86_64" "17.0"
build_opus "visionos" "visionOS" "xros" "arm64" "1.0"
build_opus "visionossim" "visionOS" "xrsimulator" "arm64" "1.0"

MACOS_UNIVERSAL="${WORK_DIR}/libopus-macos.a"
IOSSIM_UNIVERSAL="${WORK_DIR}/libopus-iossim.a"
TVOSSIM_UNIVERSAL="${WORK_DIR}/libopus-tvossim.a"

lipo_combine "${MACOS_UNIVERSAL}" \
    "${WORK_DIR}/install-macos-arm64/lib/libopus.a" \
    "${WORK_DIR}/install-macos-x86_64/lib/libopus.a"

lipo_combine "${IOSSIM_UNIVERSAL}" \
    "${WORK_DIR}/install-iossim-arm64/lib/libopus.a" \
    "${WORK_DIR}/install-iossim-x86_64/lib/libopus.a"

lipo_combine "${TVOSSIM_UNIVERSAL}" \
    "${WORK_DIR}/install-tvossim-arm64/lib/libopus.a" \
    "${WORK_DIR}/install-tvossim-x86_64/lib/libopus.a"

rm -rf "${OUTPUT_DIR}"
xcodebuild -create-xcframework \
    -library "${MACOS_UNIVERSAL}" -headers "${HEADERS_DIR}" \
    -library "${WORK_DIR}/install-ios-arm64/lib/libopus.a" -headers "${HEADERS_DIR}" \
    -library "${IOSSIM_UNIVERSAL}" -headers "${HEADERS_DIR}" \
    -library "${WORK_DIR}/install-tvos-arm64/lib/libopus.a" -headers "${HEADERS_DIR}" \
    -library "${TVOSSIM_UNIVERSAL}" -headers "${HEADERS_DIR}" \
    -library "${WORK_DIR}/install-visionos-arm64/lib/libopus.a" -headers "${HEADERS_DIR}" \
    -library "${WORK_DIR}/install-visionossim-arm64/lib/libopus.a" -headers "${HEADERS_DIR}" \
    -output "${OUTPUT_DIR}"

cp "${SOURCE_DIR}/COPYING" "${OUTPUT_DIR}/LICENSE"

echo "Created ${OUTPUT_DIR}"
