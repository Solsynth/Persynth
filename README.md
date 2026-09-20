# synth_pet

An Island-style Flutter desktop pet companion.

## Current scaffold

- Material 3 configuration dashboard with responsive desktop rail and mobile navigation.
- AutoRoute-powered home and floating-pet routes.
- Configurable ASCII face parts (`0.0`, `0-0`, `0^0`, `0.o`, and similar combinations), persisted locally.
- Personality Core chat integration using the OpenAI-compatible `/v1/chat/completions` endpoint.
- AI behavior harness lets Personality Core change mood, face, status, and animation through a validated JSON directive.
- Programmatic simulation owns energy, affection, idle decay, and feed/play/rest reactions.
- Pet chat accepts typed messages on every target and speech-to-text on Android, iOS, and web when available.
- Solar Network OAuth with PKCE, secure token storage, refresh, and sign-out.
- Desktop-only multi-window support through `desktop_multi_window`.
- Pet-only agent listing: the companion picker and dashboard show only `pet`-capable
  agents (`GET /agents?pet=true`).
- Bond dashboard: the configuration page shows each pet's Personality Core
  affection score (0-100, with level and latest reason) and a reset action that
  purges that agent's memories and conversation history for the account
  (`GET /pet/affection`, `DELETE /agents/:id/memories`).
- Desktop window chrome from `island_ui_foundation` and `window_manager`.

Mobile builds use the regular single-window Flutter app shell.

Sign in from the main configuration window. The app passes the refreshed Solar
Network user access token to Personality Core; it never asks for a separate
Personality Core token.

Register both `synthpet://oauth/callback` and
`http://127.0.0.1:42872/oauth/callback` with the Solar Network OAuth client.
Windows and Linux use the fixed loopback callback through the system browser;
mobile and macOS use the `synthpet` callback scheme.

If the registered OAuth client or Personality Core agent differs from the
defaults, configure them at build/run time:

```sh
flutter run \
  --dart-define=SOLAR_OAUTH_CLIENT_ID=synthpet \
  --dart-define=PERSONALITY_CORE_AGENT=agent
```

## Development

```sh
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

The app is sandboxed, so its file and command tools (`Files & commands` in
settings) run in the SynthPet MCP daemon — a separate, unsandboxed process
under `tool/synthpet_mcp`:

```sh
cd tool/synthpet_mcp && dart pub get && dart run synthpet_mcp
```

The daemon listens on `127.0.0.1:4317/mcp` (override with `--port`, or point
the app at another URL with `--dart-define=SYNTHPET_MCP_URL=...`). Compile it
with `dart compile exe bin/synthpet_mcp.dart` for a standalone binary; grant
that binary Full Disk Access to reach macOS-protected folders.
