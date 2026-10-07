#!/bin/sh

# Xcode Cloud runs this script after cloning the repository, before Xcode
# builds ios/Runner.xcworkspace. It installs the toolchain the archive needs and
# generates the Xcode configuration, so the build phase does not have to.

# Fail this script if any subcommand fails.
set -e

# The default execution directory is ios/ci_scripts/. Move to the repository root.
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "=== Installing Flutter SDK ==="
# Clone the stable Flutter SDK from Git into the home folder
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
export PATH="$PATH:$HOME/flutter/bin"

# Pre-cache iOS artifacts and fetch dependencies
flutter precache --ios
# Retry + HTTP/1.1: the Socommon git dependencies clone from src.solsynth.dev
# behind Cloudflare, which intermittently resets large pack transfers (curl 56).
git config --global http.version HTTP/1.1
for attempt in 1 2 3; do
  flutter pub get && break
  echo "flutter pub get failed (attempt $attempt); retrying in 10s"
  sleep 10
done

echo "=== Installing Rust ==="
# super_context_menu depends on super_native_extensions, whose crate is compiled
# by cargokit from the plugin's CocoaPods script phase while Xcode builds the
# target. cargokit prefers prebuilt binaries from the crate's GitHub releases and
# falls back to a source build, and that fallback runs `rustup` — looked up in
# $HOME/.cargo/bin before PATH — and installs whatever target it needs itself.
# Doing both here keeps the archive from shelling out to rustup.rs or GitHub in
# the middle of the build.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
export PATH="$HOME/.cargo/bin:$PATH"

# The crate ships no rust-toolchain.toml, so cargokit builds with rustup's
# default `stable` toolchain; the Apple targets belong on that one.
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

echo "=== Installing CocoaPods ==="
# Disable homebrew auto-updates to save CI time
HOMEBREW_NO_AUTO_UPDATE=1 brew install cocoapods

# Install iOS pods
echo "=== Running Pod Install ==="
cd ios
pod install --repo-update

# The distribution configuration the GitHub workflows pass as --dart-define is
# baked into ios/Flutter/Generated.xcconfig here, which the archive's build phase
# then reads. Forward the values when the Xcode Cloud workflow defines them;
# without DISTRIBUTION_PRODUCT_ID the app has no product to check, so it ships
# with update checks disabled. Neither value contains whitespace.
dart_defines=""
for name in DISTRIBUTION_API_BASE_URL DISTRIBUTION_PRODUCT_ID; do
  value=$(printenv "$name" || :)
  if [ -n "$value" ]; then
    dart_defines="$dart_defines --dart-define=$name=$value"
  fi
done

# Return to the root and generate the configurations the archive reads
# (ios/Flutter/Generated.xcconfig, Flutter.podspec) without building twice.
cd "$CI_PRIMARY_REPOSITORY_PATH"
flutter build ios --config-only $dart_defines

echo "=== Script finished successfully ==="
exit 0
