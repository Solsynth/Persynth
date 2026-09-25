/// The on-device web tool set, as a plugin.
///
/// These tools only make requests the server would have made anyway, merely
/// from the user's own connection — which is why they are on by default and
/// eager: two small definitions the companion reaches for constantly.
library;

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/personality/local_web_tools.dart';
import 'package:persynth/plugins/plugin.dart';

/// The key this switch is persisted under.
///
/// It predates the plugin registry, when the switch was one field of a
/// two-field settings object; keeping the name keeps the choice of every user
/// who already made it.
const String kLocalWebToolsStoreKey = 'persynth_local_tools_web';

class WebToolsPlugin extends SnPlugin {
  const WebToolsPlugin();

  @override
  String get id => 'web';

  @override
  String get storeKey => kLocalWebToolsStoreKey;

  @override
  String get label => 'Web search & fetch';

  @override
  String get description =>
      'Runs web_search and web_fetch from this machine\'s own connection '
      'instead of the server\'s.';

  @override
  String get summary =>
      'Search the web and fetch pages from the user\'s own connection';

  @override
  bool get enabledByDefault => true;

  @override
  Map<String, String> get overrides => const {
    'web_search': 'web_search',
    'read_webpage': 'web_fetch',
  };

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) =>
      buildLocalWebTools(context.http);

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'Web tools that run on the user\'s own device are loaded: '
    'local_web_search and local_web_fetch leave from the user\'s IP address, '
    'which search engines do not challenge with bot checks. Prefer them to the '
    'server-side web_search and web_fetch when both are available.',
  ];
}
