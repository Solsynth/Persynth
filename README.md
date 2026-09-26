# persynth

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

## Plugins

Everything the companion can do on this machine is a plugin: the on-device web
tools, the MCP-backed file and shell tools, and any script plugin the user
installs. A plugin owns three things — the tools the model may call, the system
prompt text that explains them, and the settings switch the user grants it
with. Nothing in the chat loop, the run request or the settings page names one:
they all read `lib/plugins/plugin_registry.dart`, so adding a capability is one
class plus one line in `kBuiltInPlugins`.

A plugin that is switched off is not offered to the model at all, so the switch
is a capability boundary rather than a refusal the model could argue past.

### Eager and on-demand tools

A plugin's tools ride on every run, or — if it sets `onDemand` — load only once
the model asks for them by name, through `list_skills`. That is worth doing when
a tool set is large or rarely used: its definitions cost context on every
request whether or not they are called. `Files & commands` is on demand for
exactly that reason.

### Replacing the server's tools

Some of these tools do what a server-side tool already does — the app's
`web_search` against the server's, `read_timeline` against its `list_feed`. A
plugin declares those in `overrides`, and the server drops its own copies for
the run. The model is offered one tool per job, and the one that survives is
the one that leaves from the user's own address carrying their token, which is
the whole point of running it here.

The declaration is a map of the server's tool name to the local tool that
replaces it, and it is held to that claim: a test requires every name to match
a tool the plugin actually offers. An override removes the server's tool, so a
claim with nothing behind it would delete a capability rather than move one.

Only the *loaded* plugins override anything. Enabling an on-demand set changes
nothing until the model loads it; loading is what tells the server, on the same
resume that hands over the new tools, to take its copies back.

A skill is hidden from `list_skills` only when every tool it would add has been
replaced. A half-replaced skill stays listed, because activating it still adds
the tools the caller did not claim.

### The Solar Network sets

Most of what ships is the user's own Solar Network account, reached from this
machine with their token. Each set is its own switch, and all of them start
off: reading someone's messages or posting in their name is a grant they make,
not one the app assumes.

| Switch | Id | Tools | Load |
| --- | --- | --- | --- |
| Moments & feed | `social` | `read_timeline`, `read_post`, `search_posts`, `read_profile`, `create_post`, `reply_to_post`, `react_to_post` | on demand |
| Messages | `chat` | `read_conversations`, `read_conversation`, `send_message`, `message_someone`, `unread_messages` | on demand |
| Notifications | `notifications` | `read_notifications`, `unread_notifications`, `mark_all_notifications_read` | every run |
| Calendar | `agenda` | `read_agenda`, `next_notable_day`, `create_event` | every run |
| Daily rituals | `ritual` | `daily_fortune`, `today_check_in`, `check_in` | every run |
| Profile & standing | `profile` | `whoami`, `read_account`, `social_credits`, `achievements` | on demand |
| Wallet | `wallet` | `read_wallet`, `wallet_stats` | on demand |

The tool names above are what the plugin calls them. The model reads them under
the server's `local_` prefix, like every other caller-owned name.

### Why the tools name their own paths

They do not go through `solar_network_sdk`. That client's routes and response
models have both drifted from the services they describe, and the drift only
shows up at runtime: the home feed, post search, a publisher's posts, the daily
fortune, every room-scoped chat call and both notification writes answered
`404`, one method swallowed a `404` into `null` so its tool reported "nothing
there" forever, and parsing a response threw
`type 'Null' is not a subtype of type 'num'` on a field the server had stopped
sending.

So a tool names its path and projects only the fields it reports, which makes a
field that disappears a missing value rather than an exception. To check the
paths are still there after a service upgrade:

```sh
dart run tool/verify_solar_routes.dart
```

It exercises every path the tools call against the live gateway — an endpoint
that exists answers `401` without a token, a path that has moved answers `404` —
and exits non-zero if any is gone.

Two of the sets are worth reading before adding more. **Wallet is read-only by
construction**: moving money on Solar Network is authorised by the user's local
payment PIN, which this app does not hold and must not ask for, so there is no
transfer, order or gift tool anywhere in it. And **there is no per-notification
mark-read**: the service has no route for one, and listing notifications is what
marks them viewed — which is why `read_notifications` sends `unmark=true`, so
reading the inbox leaves it exactly as it was.

### Script plugins

A plugin can also be JavaScript, run in its own sandbox by
`island_plugin_foundation` (QuickJS), with its own permissions and a quarantine
for one that crashes on load. Each lives in a folder with a `manifest.json` and
an entry script:

```
my_plugin/
  manifest.json
  main.js
```

```javascript
function on_load() {
  agent_tools.register_tool(
    "discount",
    "Look up the discount on an order.",
    '{"type":"object","properties":{"order":{"type":"string"}},"required":["order"]}',
    "lookup_discount"
  );
}

function lookup_discount(args) {
  return { order: args.order, percent: 10 }; // objects go to the model as JSON
}
```

Install one by copying the folder into the app's plugin directory
(`{appSupport}/plugins`) and restarting; it appears in settings with its own
switch. Handlers run synchronously, the same way the runtime's own commands and
hooks do — a tool that needs the network should call a host API rather than
fetch on its own.

### Names

Tool and skill names are the app's own (`web_search`, `discount`). The
Personality server puts every caller-owned name under its client namespace
before the model sees it — `local_web_search`, `local_discount` — which is what
makes a client tool unable to shadow a server tool, and what lets the model
tell which side a capability runs on. The namespace is the server's to add;
applying it here too would double it.

## Development

```sh
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

The app is sandboxed, so its file and command tools (`Files & commands` in
settings) run in the Persynth MCP daemon — a separate, unsandboxed process
under `tool/synthpet_mcp`:

```sh
cd tool/synthpet_mcp && dart pub get && dart run synthpet_mcp
```

The daemon listens on `127.0.0.1:4317/mcp` (override with `--port`, or point
the app at another URL with `--dart-define=SYNTHPET_MCP_URL=...`). Compile it
with `dart compile exe bin/synthpet_mcp.dart` for a standalone binary; grant
that binary Full Disk Access to reach macOS-protected folders.
