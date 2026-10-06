# Releasing Persynth

Two workflows live in `.github/workflows`:

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `analyze.yml` | pull requests | `flutter pub get`, code generation, `flutter analyze lib` |
| `build.yml` | any tag push, or manual dispatch | builds Windows, Linux, Android and uploads them to Solsynth Express |

`build.yml` also accepts a manual run with a `platform` choice (`all`, `windows`,
`linux`, `android`) for building a single platform without touching the
distribution. A manual run records the newest existing tag as the distribution
version, so it fails before uploading while the repository has no tags.

## Cutting a release

1. Bump `version:` in `pubspec.yaml` (`<semver>+<build number>`). The Windows
   installer and the Android APKs read the version from there.
2. Commit, then push a tag:

   ```bash
   git tag 1.0.0+4
   git push origin 1.0.0+4
   ```

   The tag name is the version recorded in the distribution, and the update
   check compares an installed build against it, so it has to be the same
   string `pubspec.yaml` reports — `<semver>+<build number>`, no `v` prefix.
3. Wait for the four jobs (`build-windows`, `build-linux`, `build-android`,
   `upload-to-distribution`). Artifacts also stay downloadable from the run.
4. Review the draft release in the Solsynth Express console and publish it.
   Uploading never publishes on its own.

## Artifacts

| Platform | Artifact |
| --- | --- |
| Windows | `windows-x86_64-setup.exe` (Inno Setup, from `setup.iss`) |
| Linux | `Persynth-x86_64.AppImage` (from `buildtools/build-appimage.sh`) |
| Android | `app-arm64-v8a-release.apk`, `app-armeabi-v7a-release.apk`, `app-x86_64-release.apk` |

macOS and iOS are archived by Xcode Cloud, not by `build.yml`; their icons come
from the `ios/AppIcon.icon` bundle, which CI does not need.

## Xcode Cloud

Each platform has a workflow that archives its workspace — `ios/Runner.xcworkspace`,
`macos/Runner.xcworkspace` — with the archive action on the default environment.
The `Runner` schemes are shared in both projects, which is what Xcode Cloud picks
up. Signing, the App Store Connect product records and the bundle identifiers are
configured there and in Xcode, not in this repository.

The post-clone hooks below run first and prepare the checkout:

| Script | Prepares |
| --- | --- |
| `ios/ci_scripts/ci_post_clone.sh` | stable Flutter, Rust, CocoaPods, iOS pods |
| `macos/ci_scripts/ci_post_clone.sh` | stable Flutter, Rust, CocoaPods, macOS pods |

Both follow the same order: clone stable Flutter into `$HOME/flutter`,
`flutter pub get` (with the retry `analyze.yml` and `build.yml` use for the
Socommon git dependencies), install Rust, install CocoaPods,
`pod install --repo-update`, and finally `flutter build <platform> --config-only`.
That last step writes the `xcconfig` files and `Flutter.podspec` the archive's
build phase reads, so Xcode compiles the app once instead of twice.

Both hooks forward `DISTRIBUTION_API_BASE_URL` and `DISTRIBUTION_PRODUCT_ID` from
the workflow's environment variables, matching the `--dart-define`s `build.yml`
passes. **Set both in each workflow's Environment section**: `kDistributionProductId`
has no default, so an archive without them ships with update checks silently
disabled (see [In-app updates](#in-app-updates)).

Rust is required. `super_context_menu` depends on `super_native_extensions`, whose
crate cargokit compiles from the plugin's CocoaPods script phase while Xcode
builds the target — the pod carries the Rust source, not the library. cargokit
prefers prebuilt binaries from the crate's GitHub releases and falls back to a
source build; that fallback finds `rustup` in `$HOME/.cargo/bin` before `PATH` and
installs the target it needs itself, so the hooks install Rust and add
`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` (iOS) or both
`apple-darwin` targets (macOS) up front, keeping the archive from reaching for
rustup.rs or GitHub mid-build. The crate ships no `rust-toolchain.toml`, which is
why the targets go on rustup's default `stable` toolchain.

Both hooks track the stable channel, like the other workflows, and are meant for
a disposable Xcode Cloud machine: they clone a Flutter SDK into `$HOME/flutter`
and install CocoaPods, so a developer's checkout keeps using its own toolchain.

## In-app updates

The app asks Solsynth Express whether a newer release exists — on launch, unless
the user has switched that off in settings, and whenever the user asks in the
same section. `lib/shared/app_update.dart` holds the only code that reaches for
the client, and the sheet comes from `solsynth_express`.

A build made without the two variables above checks nothing: the product id is
empty, so the client is unconfigured and asks no product at all, rather than
falling back to the product the package defaults to. To exercise the check from
a local build, hand it the product explicitly:

```bash
flutter run \
  --dart-define=DISTRIBUTION_API_BASE_URL=https://api.solian.app/dist \
  --dart-define=DISTRIBUTION_PRODUCT_ID=<Persynth's product id>
```

Android installs a downloaded APK itself, which needs the
`REQUEST_INSTALL_PACKAGES` permission and the `FileProvider` in
`android/app/src/main/AndroidManifest.xml`; both are in the manifest, and the
provider's authority is the one the update plugin defaults to.

## Dependencies

The Socommon packages (`island_ui_foundation`, `island_plugin_foundation`,
`solar_network_foundation`, `solsynth_express`) are git dependencies of
`https://src.solsynth.dev/SoSYS/Socommon.git`, each pinned to one `ref`. Keep the
pins on the same revision: pub identifies a git dependency by url + path + ref,
and the packages depend on each other by path inside that checkout, so a
floating HEAD resolves one package from two sources and version solving fails.

`pubspec.lock` is resolved from those git sources, which is what CI checks out.
A local `pubspec_overrides.yaml` pointing the packages at a sibling Socommon
checkout is supported (it is gitignored) but rewrites the lockfile to
`source: path`; restore `pubspec.lock` before committing. The `analyze.yml`
workflow fails any pull request whose lockfile is not what `flutter pub get`
produces from the git dependencies.

## Repository configuration

Settings → Secrets and variables → Actions.

### Variables

| Name | Value |
| --- | --- |
| `DISTRIBUTION_API_BASE_URL` | Solsynth Express API base, including the `/api` prefix |
| `DISTRIBUTION_PRODUCT_ID` | Persynth's product id in Solsynth Express |

Both are read twice: the upload job publishes the artifacts with them, and each
build job passes them to `flutter build` as
`--dart-define=DISTRIBUTION_API_BASE_URL` / `--dart-define=DISTRIBUTION_PRODUCT_ID`.
That is what lets the built app check the same product it was published to; see
[In-app updates](#in-app-updates).

### Secrets

| Name | Value |
| --- | --- |
| `DISTRIBUTION_UPLOAD_KEY` | Solsynth Express upload key for the product |
| `ANDROID_KEYSTORE_BASE64` | base64 of the release `.jks` |
| `ANDROID_KEY_ALIAS` | key alias inside the keystore |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password, also used as the key password |

Create the Android entries from an existing release keystore:

```bash
base64 < release.jks | tr -d '\n'   # ANDROID_KEYSTORE_BASE64
keytool -list -v -keystore release.jks   # confirm the alias
```

The Android job writes `android/app/release.jks` and `android/key.properties`
into the workspace; both are gitignored. Without those secrets the job fails at
the `Configure Android signing` step, and a local `flutter build apk --release`
falls back to the debug keys so development builds keep working.

## Android toolchain

`android/settings.gradle.kts` pins AGP `9.0.1` and
`android/gradle/wrapper/gradle-wrapper.properties` pins Gradle `9.1.0`;
`android/app/build.gradle.kts` compiles against SDK `37`, which Gradle
downloads on demand. The plugin set has no `jcenter()` or
`getDefaultProguardFile('proguard-android.txt')` call left, so it configures on
the Gradle 9 line - unlike the sibling repositories, which still pin AGP
`8.12.1` / Gradle `8.14` for plugins that do.
