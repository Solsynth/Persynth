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
   git tag v1.0.0
   git push origin v1.0.0
   ```

   The tag name is the version recorded in the distribution; the `pubspec.yaml`
   version is what the built binaries report.
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

macOS and iOS build from a local Xcode/Flutter run; their icons come from the
`ios/AppIcon.icon` bundle, which CI does not need.

## Dependencies

The Socommon packages (`island_ui_foundation`, `island_plugin_foundation`,
`solar_network_foundation`) are git dependencies of
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
