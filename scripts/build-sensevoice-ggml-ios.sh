#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/SenseVoiceGGML"
SOURCE_DIR="$VENDOR_DIR/source"
BUILD_DIR="$VENDOR_DIR/build"
OUTPUT_DIR="$VENDOR_DIR/output"
PUBLIC_HEADERS_DIR="$OUTPUT_DIR/include"
UPSTREAM_REPO="https://github.com/lovemefan/SenseVoice.cpp"
MIN_IOS_VERSION="${MIN_IOS_VERSION:-17.0}"

mkdir -p "$VENDOR_DIR" "$BUILD_DIR" "$OUTPUT_DIR" "$PUBLIC_HEADERS_DIR"

if [ ! -d "$SOURCE_DIR/.git" ]; then
  git clone --recurse-submodules "$UPSTREAM_REPO" "$SOURCE_DIR"
fi

cp "$ROOT_DIR/EarPal/SenseVoiceGGMLBridge.h" "$PUBLIC_HEADERS_DIR/SenseVoiceGGMLBridge.h"

build_sdk() {
  local sdk="$1"
  local platform_name="$2"
  local build_path="$BUILD_DIR/$sdk"
  local sdk_path
  local wrapper_object
  local wrapper_archive
  local release_dir
  local libsense_voice
  local libggml
  local libggml_base
  local libggml_cpu
  local libggml_metal
  local min_flag

  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  wrapper_object="$build_path/SenseVoiceGGMLBridge.o"
  wrapper_archive="$build_path/libSenseVoiceGGML.a"

  if [ "$sdk" = "iphonesimulator" ]; then
    min_flag="-mios-simulator-version-min=$MIN_IOS_VERSION"
  else
    min_flag="-miphoneos-version-min=$MIN_IOS_VERSION"
  fi

  cmake -S "$SOURCE_DIR" -B "$build_path" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS_VERSION" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DBUILD_SHARED_LIBS=OFF \
    -DSENSE_VOICE_BUILD_EXAMPLES=OFF \
    -DSENSE_VOICE_BUILD_TESTS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON

  cmake --build "$build_path" --config Release --target sense-voice-core

  release_dir="$(find "$build_path" -type d \( -name "Release-$sdk" -o -name "Release" \) | head -n 1)"
  if [ -z "$release_dir" ]; then
    echo "Release output directory not found for $sdk"
    exit 1
  fi

  libsense_voice="$(find "$build_path" -name "libsense-voice-core.a" | head -n 1)"
  libggml="$(find "$build_path" -name "libggml.a" | head -n 1)"
  libggml_base="$(find "$build_path" -name "libggml-base.a" | head -n 1)"
  libggml_cpu="$(find "$build_path" -name "libggml-cpu*.a" | head -n 1)"
  libggml_metal="$(find "$build_path" -name "libggml-metal*.a" | head -n 1)"

  xcrun clang++ -c "$ROOT_DIR/Native/SenseVoiceGGMLBridge.mm" \
    -o "$wrapper_object" \
    -arch arm64 \
    -isysroot "$sdk_path" \
    $min_flag \
    -fobjc-arc \
    -std=c++17 \
    -I"$ROOT_DIR/EarPal" \
    -I"$SOURCE_DIR/sense-voice/csrc" \
    -I"$SOURCE_DIR/sense-voice/csrc/third-party/ggml/include" \
    -I"$SOURCE_DIR/sense-voice/csrc/third-party/ggml/src"

  libtool -static \
    -o "$wrapper_archive" \
    "$wrapper_object" \
    "$libsense_voice" \
    "$libggml" \
    "$libggml_base" \
    "$libggml_cpu" \
    "$libggml_metal"
}

build_sdk iphoneos "iOS"
build_sdk iphonesimulator "iOS Simulator"

xcodebuild -create-xcframework \
  -library "$BUILD_DIR/iphoneos/libSenseVoiceGGML.a" \
  -headers "$PUBLIC_HEADERS_DIR" \
  -library "$BUILD_DIR/iphonesimulator/libSenseVoiceGGML.a" \
  -headers "$PUBLIC_HEADERS_DIR" \
  -output "$OUTPUT_DIR/SenseVoiceGGML.xcframework"
