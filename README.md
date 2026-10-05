# persynth

An Island-style Flutter desktop pet companion.

## Current scaffold

- Material 3 configuration dashboard with responsive desktop rail and mobile navigation.
- AutoRoute-powered home and floating-pet routes.
- Configurable ASCII face parts (`0.0`, `0-0`, `0^0`, `0.o`, and similar combinations), persisted locally.
- Personality Core chat integration using the OpenAI-compatible `/v1/chat/completions` endpoint.
- Reasoning effort lives in the chat composer as a pill: `Low`, `Medium` or
  `High`, sent with every run as `reasoning_effort` and remembered across
  launches. No level lit is the model's own default — the run goes out without
  an effort, leaving the decision to the provider — and tapping the lit level
  again returns to it. A chosen level also states `disable_reasoning: false`,
  so the run reasons even on an agent whose config turns thinking off by
  default; the untouched state leaves that field out and lets the agent
  decide. A level an older build stored under its own token still reads back
  as itself.
- AI behavior harness lets Personality Core change mood, face, status, and animation through a validated JSON directive.
- Programmatic simulation owns energy, affection, idle decay, and feed/play/rest reactions.
- Pet chat accepts typed messages on every target and speech-to-text on Android, iOS, and web when available. A block pasted into the composer at least 1000 characters long becomes a text attachment instead of message text: it can be opened and edited in place until the turn is sent, and then travels with the run as a named text part — the companion reads it as a document, and nothing is uploaded to Solar Network drive.
- A picked image becomes a tile on the composer immediately, showing the picture from this device while it goes up to Solar Network drive on a pool of three uploads of its own; the tile wears how far it has got, and the turn waits until every file has landed. A file whose upload failed stays on the strip with its reason: tap the tile to send it again, or remove it — removing aborts the upload mid-flight. Nothing is ever dropped from a message silently, and a turn carrying only an image needs no text at all.
- The composer's attach button offers the account's own drive as well as the device: a file uploaded for an earlier message is linked by the id it already has, searched by name in a sheet that lists the drive's images newest first, or pasted as an id when the listing does not show it. Nothing is uploaded again, so a file from months ago costs one tap and no traffic.
- A sent image keeps its picture: the turn draws the file on this device while it is still there, and the drive's own copy — fetched with the account token — for a linked file or a thread replayed from the server, so a preview never falls back to a placeholder as the message leaves the composer.
- Any picture opens full screen, laid over the conversation it came from: pinch, wheel or double-tap to zoom into a spot, drag to pan once it is bigger than the window, swipe across for the next picture in the turn, pull down to let it go. The chrome — the name, how far through the set you are, zoom, fit and rotate — steps aside by itself after three seconds and comes back on a tap; `Esc` closes, the arrows turn the page, `+` `-` zoom and `F` fits. It grows out of the tile it was tapped, and the pictures either side are built so a swipe is instant.
- Whether the companion can read an image is the model's to say, not the app's: `GET /personality/models` lists which models take image input. The agent here runs DeepSeek's Flash line, which reads images natively, so a picked picture reaches the model itself rather than a description of one — as long as the server knows that (Personality Core resolves it from the model's declared modalities, a provider flag, or its built-in knowledge of well-known multimodal models).
- Solar Network OAuth with PKCE, secure token storage, refresh, and sign-out,
  behind a sign-in gate the app opens on.
- Desktop-only multi-window support through `desktop_multi_window`.
- MCP servers the user connects from settings, each an on-demand plugin whose
  tools the companion can load; tokens stay in the keychain, desktop and mobile
  only.
- Desktop window chrome from `island_ui_foundation` and `window_manager`.

Mobile builds use the regular single-window Flutter app shell.

The app opens on its gate (`lib/gate/gate_page.dart`): the Solar Network
sign-in is the front door, and the conversation is only reachable from it, so a
launch with no session never lands on a chat surface that cannot send anything.
Nothing else owns a sign-in — the gate and the conversation both render
`SolarSignInPanel`, which is also what shows the code a web sign-in has to have
approved.

The conversation carries its own unauthorized status. A session the server
refuses mid-use — a 401 that could not be refreshed, or a 403 — replaces the
thread and its composer with that status rather than an error banner over a
dead input, and the sign-in sits in it: the reader keeps the screen instead of
being pulled back to the gate. Signing in from anywhere drops the last
account's agents, threads and open conversation
(`lib/personality/personality_session.dart`).

A finished turn reports what it spent, and the conversation keeps the running
tab. Both live in the composer's instrument strip, under the input where the
next message is written: the reasoning-effort pill that decides how hard the
companion thinks, and a context readout of the fullest prompt the model has
seen against its window, the conversation's tokens, and its runs. The numbers
come from the server — the total and peak context are read from
`GET /personality/conversations/:id/usage` — so they match what every other
client sees and what billing was metered against. The share of the window is
the ring beside those numbers: it fills from the top as the context does,
taking the accent as the window fills and the error tone at its end. A model
whose context ceiling the server cannot resolve gets a token count with no
window rather than a ratio against a guess — and no ring.

Settings → **Usage** is the account side of that readout: where the composer
says what one turn cost, the tab says what the account has spent and which call
spent it. It reads the ledger the server already keeps for settlement
(`GET /personality/billing/me/ledger`), so the figures are the charges that were
actually metered rather than a client-side tally. A window — 24 hours, 7 days, 30
days — totals the spend per currency (a total each, because adding golds to bits
means nothing) and then breaks the same window down by action, by endpoint, by
device, by address and by credential. Those breakdown rows are the filter:
tapping one narrows the charges listed under it to that device, endpoint or
action, and the breakdown keeps showing the whole window while it does, so
drilling down never loses the overview it was chosen from. A charge reads as a
receipt line, its amount right-aligned in mono — the action it was, the model or
engine it was priced as, and the endpoint, device, address and time of the call
behind it.

The engine choice sits above that breakdown, because it is the one setting that
decides the price of a search rather than reporting it. The engines the server
offers are priced one by one (`GET /personality/web/search/engines`) and the
pick is recorded (`PUT /personality/web/search/preference`); the choice restricts
searches to that engine rather than merely preferring it, and it covers the
`web_search` the model runs mid-conversation, not only the ones asked for by
hand. Keeping to a free engine is therefore a real answer to cost, and needs no
payment wallet. The card says so plainly while the on-device search plugin is
on — then the call leaves from this machine and the server never sees it.

The thread list — the sidebar on a wide window, the sheet on a narrow one — is
where a conversation is managed, and it is dense on purpose: a conversation is
one line, its title leading and its agent and last activity trailing it, so a
long account stays scannable. A row's actions are its context menu, on a
secondary click: move it into a group, take it out of one, or delete it, with
deletion as the marked-destructive item. Nothing separates the rows. Selecting
is still the long press — the first one starts a selection, and the strip above
the list moves the whole set into a group or deletes it behind one
confirmation. Deletion takes the thread with its messages and runs
(`DELETE /personality/conversations/:id`,
`POST /personality/conversations/batch-delete`); what the companion learned
from it stays in the memory store, which is its own explicit action
(`DELETE /personality/agents/:id/memories`).

On Android and iOS the long press belongs to the selection, so rows carry no
context menu there and those actions are the strip's; a group tile never joins
a selection, so its menu opens on a long press on every target.

Groups (`/personality/conversation-groups`) are named collections the account
owns, at most one per conversation, and appear inside the list itself as
collapsible tiles — the accounts with no groups see the plain list. A tile
starts folded and opens on a tap to show its conversations; its context menu
renames, archives and deletes it. They are also the mark of the conversations
that matter: what the companion learns while talking in a grouped thread is
pinned in the memory store, injected into every later run outside the long-term
budget and named by its group. Filing an existing conversation under a group
pins what it has already taught. Archiving a group takes it and its
conversations out of the list and gathers it under an `Archived` tile, while
the retention stays in force and unarchiving restores it. Deleting a group
ungroups its conversations and releases that retention; the memories stay
active, they simply go back to competing for the budget.

The app passes the refreshed Solar Network user access token to Personality
Core; it never asks for a separate Personality Core token.

Register the callback for every target that uses one with the Solar Network
OAuth client:

- `synthpet://oauth/callback` — Android, iOS and macOS.
- `http://127.0.0.1:42872/oauth/callback` — Windows and Linux, which cannot
  register a scheme and listen on that fixed loopback port instead.

The web build needs no callback and no registration: a browser cannot hand an
HTTPS redirect back into the page the app is running in, so the web signs in
with the OAuth **device flow** instead. It shows a code, opens
`id.solian.app/auth/device`, and polls until the account approves it — which
also means a web sign-in works from any origin, including a dev server on a
random port.

If the registered OAuth client or Personality Core agent differs from the
defaults, configure them at build/run time:

```sh
flutter run \
  --dart-define=SOLAR_OAUTH_CLIENT_ID=synthpet \
  --dart-define=PERSONALITY_CORE_AGENT=agent
```

## Plugins

Everything the companion can do on this machine is a plugin: the on-device web
tools, the Solar Network sets, any script plugin the user installs, and any MCP
server the user connects. A plugin owns three things — the tools the model may
call, the system prompt text that explains them, and the settings switch the
user grants it with. Nothing in the chat loop, the run request or the settings
page names one: they all read `lib/plugins/plugin_registry.dart`, so adding a
capability is one class plus one line in `kBuiltInPlugins`.

A plugin that is switched off is not offered to the model at all, so the switch
is a capability boundary rather than a refusal the model could argue past.

### Eager and on-demand tools

A plugin's tools ride on every run, or — if it sets `onDemand` — load only once
the model asks for them by name, through `list_skills`. That is worth doing when
a tool set is large or rarely used: its definitions cost context on every
request whether or not they are called. `Moments & feed` is on demand for
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
| Mail | `mail` | `read_mailbox`, `read_mail`, `read_email`, `unread_mail`, `send_email`, `mark_mail`, `move_mail` | on demand |
| Boards | `boards` | `list_boards`, `list_tasks`, `read_task`, `create_task`, `update_task`, `list_task_comments`, `add_task_comment` | on demand |

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

### Your own MCP servers

A Model Context Protocol server the user connects is a plugin too, one per
server. Settings → **Connections** takes a name, an endpoint and an optional
access token; the server then appears among the plugin switches like anything
else, and its tools load by name once the model asks for them.

**Paste JSON config** in the same section takes the file another client
already has — `mcpServers` as Claude Desktop, Cursor, Windsurf and `.mcp.json`
write it, `servers` as VS Code does — and adds its http(s) servers, bearer
tokens included. What it cannot take it reports by name: a `command` entry is a
stdio server, which this app does not launch, and headers beyond the
authorization one are dropped because the connection carries only a token
(`lib/plugins/mcp_config.dart`).

The app is an MCP client over Streamable HTTP (`lib/plugins/mcp_client.dart`).
It lists the server's tools, offers them on the run with the definitions the
server wrote, and forwards the model's calls back to the server they came from.
Only HTTP(S) is supported: the spec's stdio transport spawns a child process,
and a child of the sandboxed app inherits the sandbox — which is why
`tool/synthpet_mcp` is a separate daemon rather than a library.

Four things this arrangement has to get right, and where:

- **Names.** The model reads one flat list of caller-owned names, and two
  servers may both expose `search`. Every tool is registered as
  `mcp_<server>_<tool>`, sanitized into the shape the provider accepts and
  capped at 48 characters (`lib/plugins/mcp_server_plugin.dart`). The dispatch
  uses the server's own tool name, so nothing is ever called by a name its
  server never used.
- **Context.** A server's tool set is its own to decide, so each server is an
  on-demand plugin: its definitions cost a line in `list_skills` until the
  conversation loads it.
- **Reachability.** `buildTools` is synchronous while `tools/list` is a
  request, so the tools come from a cached listing per server
  (`lib/plugins/mcp_servers.dart`), refreshed at startup, after a change, after
  a switch is flipped on and on demand from the row. A failed refresh keeps the
  last good listing and records why: a server that is briefly down loses its
  reachability, not the capability the user granted.
- **Trust.** Tool descriptions are the server author's prose and reach the
  model; the prompt text says so. Tokens live in the keychain
  (`flutter_secure_storage`), never in the preferences the server list is
  stored in, and the account's own token is never sent to a server — the app
  talks to a third-party endpoint bare.

Web builds do not offer it: a browser cannot reach a server on the user's
machine, and cannot reach an arbitrary origin without the server opting into
CORS.

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

`tool/synthpet_mcp` is a standalone, out-of-process MCP server that gives the
companion filesystem and shell tools without the app itself leaving the App
Sandbox. It is not wired into the app: connect it like any other server, under
Settings → Connections, with the endpoint `http://127.0.0.1:4317/mcp`.

```sh
cd tool/synthpet_mcp && dart pub get && dart run synthpet_mcp
```

It listens on `127.0.0.1:4317/mcp` only (`--port` to move it). Compile it with
`dart compile exe bin/synthpet_mcp.dart` for a standalone binary; grant that
binary Full Disk Access to reach macOS-protected folders.
