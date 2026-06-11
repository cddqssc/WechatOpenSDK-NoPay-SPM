#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_XCFRAMEWORK="${SOURCE_XCFRAMEWORK:-${PACKAGE_DIR}/WechatOpenSDK-NoPay.xcframework}"
OUTPUT_XCFRAMEWORK="${OUTPUT_XCFRAMEWORK:-${PACKAGE_DIR}/WechatOpenSDK-NoPay-Dynamic.xcframework}"
BUILD_DIR="${BUILD_DIR:-${PACKAGE_DIR}/.build/dynamic-xcframework}"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-12.0}" # 腾讯 SDK 的最低支持 iOS 版本是 12.0，如果未来 SDK 升级了最低支持版本，需要同步修改这个值
FRAMEWORK_NAME="WechatOpenSDK"
FRAMEWORK="${FRAMEWORK_NAME}.framework"
BINARY="${FRAMEWORK_NAME}"

DEVICE_SOURCE="${SOURCE_XCFRAMEWORK}/ios-arm64/${FRAMEWORK}"
SIMULATOR_SOURCE="${SOURCE_XCFRAMEWORK}/ios-arm64_x86_64-simulator/${FRAMEWORK}"

if [[ ! -f "${DEVICE_SOURCE}/${BINARY}" ]]; then
  echo "Missing device binary: ${DEVICE_SOURCE}/${BINARY}" >&2
  exit 1
fi

if [[ ! -f "${SIMULATOR_SOURCE}/${BINARY}" ]]; then
  echo "Missing simulator binary: ${SIMULATOR_SOURCE}/${BINARY}" >&2
  exit 1
fi

IPHONEOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
IPHONEOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
SIMULATOR_SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMULATOR_SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"

LINKED_SYSTEM_LIBRARIES=(
  -framework Foundation
  -framework UIKit
  -framework CoreGraphics
  -framework Security
  -framework WebKit
  -lc++
)

set_plist_string() {
  local plist="$1"
  local key="$2"
  local value="$3"

  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist}"
}

prepare_framework() {
  local source_framework="$1"
  local output_framework="$2"
  local supported_platform="$3"

  mkdir -p "${output_framework}/Headers" "${output_framework}/Modules"
  ditto "${source_framework}/Headers" "${output_framework}/Headers"
  ditto "${source_framework}/Modules" "${output_framework}/Modules"
  cp "${source_framework}/Info.plist" "${output_framework}/Info.plist"

  set_plist_string "${output_framework}/Info.plist" "CFBundlePackageType" "FMWK"
  set_plist_string "${output_framework}/Info.plist" "CFBundleInfoDictionaryVersion" "6.0"
  set_plist_string "${output_framework}/Info.plist" "CFBundleName" "${FRAMEWORK_NAME}"
  set_plist_string "${output_framework}/Info.plist" "CFBundleDevelopmentRegion" "en"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleSupportedPlatforms" "${output_framework}/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "${output_framework}/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string ${supported_platform}" "${output_framework}/Info.plist"

  if [[ -f "${SOURCE_XCFRAMEWORK}/PrivacyInfo.xcprivacy" ]]; then
    cp "${SOURCE_XCFRAMEWORK}/PrivacyInfo.xcprivacy" "${output_framework}/PrivacyInfo.xcprivacy"
  fi
}

patch_build_version() {
  local platform="$1"
  local sdk_version="$2"
  local binary_path="$3"

  xcrun vtool \
    -set-build-version "${platform}" "${MIN_IOS_VERSION}" "${sdk_version}" \
    -replace \
    -output "${binary_path}.patched" \
    "${binary_path}"
  mv "${binary_path}.patched" "${binary_path}"
}

# 链接参数说明：
# 目的是把腾讯提供的静态库重新链接成一个真正的
# dynamic framework。依赖项通过 `xcrun nm -u <静态库>` 查看 undefined symbols
# 推断，再用最小链接实验确认：
#   - Foundation：NSString、NSData、NSURL、NSDictionary、NSJSONSerialization 等 NS* 符号
#   - UIKit：UIApplication、UIScreen、UIViewController、UIImage、UIImageJPEGRepresentation 等 UI* 符号
#   - CoreGraphics：CGSizeZero 等 CG 符号
#   - Security：SecItemAdd、SecItemCopyMatching、SecItemDelete 等 Keychain 符号
#   - WebKit：WKWebView、WKWebViewConfiguration 等符号
#   - libc++：__ZSt9terminatev、___cxa_begin_catch、___gxx_personality_v0 等 C++ runtime 符号
# `-Wl,-force_load,<静态库>` 会把静态库中的所有 object 都装入动态库，避免 Objective-C
# category、运行时注册或未被直接引用的代码在重链接时被裁掉。
link_device_framework() {
  local output_framework="$1"

  xcrun clang \
    -dynamiclib \
    -arch arm64 \
    -isysroot "${IPHONEOS_SDK_PATH}" \
    -miphoneos-version-min="${MIN_IOS_VERSION}" \
    -install_name "@rpath/${FRAMEWORK}/${BINARY}" \
    -Wl,-force_load,"${DEVICE_SOURCE}/${BINARY}" \
    "${LINKED_SYSTEM_LIBRARIES[@]}" \
    -o "${output_framework}/${BINARY}"

  patch_build_version ios "${IPHONEOS_SDK_VERSION}" "${output_framework}/${BINARY}"
}

link_simulator_framework() {
  local output_framework="$1"

  xcrun clang \
    -dynamiclib \
    -arch arm64 \
    -arch x86_64 \
    -isysroot "${SIMULATOR_SDK_PATH}" \
    -mios-simulator-version-min="${MIN_IOS_VERSION}" \
    -install_name "@rpath/${FRAMEWORK}/${BINARY}" \
    -Wl,-force_load,"${SIMULATOR_SOURCE}/${BINARY}" \
    "${LINKED_SYSTEM_LIBRARIES[@]}" \
    -o "${output_framework}/${BINARY}"

  patch_build_version iossim "${SIMULATOR_SDK_VERSION}" "${output_framework}/${BINARY}"
}

rm -rf "${BUILD_DIR}" "${OUTPUT_XCFRAMEWORK}"
mkdir -p "${BUILD_DIR}/ios-arm64" "${BUILD_DIR}/ios-arm64_x86_64-simulator"

DEVICE_OUTPUT="${BUILD_DIR}/ios-arm64/${FRAMEWORK}"
SIMULATOR_OUTPUT="${BUILD_DIR}/ios-arm64_x86_64-simulator/${FRAMEWORK}"

prepare_framework "${DEVICE_SOURCE}" "${DEVICE_OUTPUT}" "iPhoneOS"
prepare_framework "${SIMULATOR_SOURCE}" "${SIMULATOR_OUTPUT}" "iPhoneSimulator"
link_device_framework "${DEVICE_OUTPUT}"
link_simulator_framework "${SIMULATOR_OUTPUT}"

xcodebuild -create-xcframework \
  -framework "${DEVICE_OUTPUT}" \
  -framework "${SIMULATOR_OUTPUT}" \
  -output "${OUTPUT_XCFRAMEWORK}"

if [[ -f "${SOURCE_XCFRAMEWORK}/PrivacyInfo.xcprivacy" ]]; then
  cp "${SOURCE_XCFRAMEWORK}/PrivacyInfo.xcprivacy" "${OUTPUT_XCFRAMEWORK}/PrivacyInfo.xcprivacy"
fi

echo "Created ${OUTPUT_XCFRAMEWORK}"
