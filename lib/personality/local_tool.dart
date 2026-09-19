/// One tool whose body runs on this device rather than on the Personality
/// server.
///
/// The server dispatches the call and then waits: the app executes the body
/// locally and posts the result back to resume the run. Tool sets built on
/// this — the web tools, the device tools — are switched on and off per set in
/// settings, so only the enabled ones are ever offered to the model.
///
/// A name must not collide with a server-owned tool (`web_search`,
/// `web_fetch`, `list_files`, ...): the run is rejected rather than letting a
/// local tool shadow the server's. Hence the `_local` suffixes.
class SnLocalTool {
  const SnLocalTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  /// Wire name the model calls; must not collide with a server-owned tool.
  final String name;

  /// Prose the model reads when deciding whether to call this tool.
  final String description;

  /// JSON Schema of the arguments object (`function.parameters`).
  final Map<String, dynamic> parameters;

  /// Runs the tool and returns the text handed back to the model.
  final Future<String> Function(Map<String, dynamic> arguments) execute;

  /// The OpenAI `tools[]` entry the compatibility endpoint accepts verbatim.
  Map<String, dynamic> toOpenAiTool() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}
