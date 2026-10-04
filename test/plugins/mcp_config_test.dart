import 'package:flutter_test/flutter_test.dart';

import 'package:persynth/plugins/mcp_config.dart';

void main() {
  test('the de-facto mcpServers file is read, token and all', () {
    final config = readMcpConfig('''
{
  "mcpServers": {
    "weather": {
      "url": "https://weather.example/mcp",
      "headers": {"Authorization": "Bearer wx-key"}
    },
    "notes": {"url": "http://127.0.0.1:4317/mcp"}
  }
}
''');

    expect(config.skipped, isEmpty);
    expect(config.servers.map((server) => server.name), ['weather', 'notes']);
    expect(config.servers.first.url, Uri.parse('https://weather.example/mcp'));
    // The header is a credential the user does not have to retype.
    expect(config.servers.first.token, 'wx-key');
    expect(config.servers.last.token, isNull);
    expect(config.servers.last.note, isNull);
  });

  test('VS Code writes the same servers under `servers`', () {
    final config = readMcpConfig('''
{"servers": {"home": {"type": "http", "url": "http://127.0.0.1:4317/mcp"}}}
''');

    expect(config.servers.single.name, 'home');
  });

  test('the inner object on its own is read too', () {
    final config = readMcpConfig(
      '{"home": {"url": "http://127.0.0.1:4317/mcp"}}',
    );

    expect(config.servers.single.url.port, 4317);
  });

  test('a server this app would have to launch is reported, not added', () {
    final config = readMcpConfig('''
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    },
    "weather": {"url": "https://weather.example/mcp"}
  }
}
''');

    // One unusable entry does not cost the user the usable ones.
    expect(config.servers.single.name, 'weather');
    expect(config.skipped.single, contains('npx'));
    expect(config.skipped.single, contains('filesystem'));
  });

  test('an entry with no endpoint or an unusable one is reported', () {
    final config = readMcpConfig('''
{
  "mcpServers": {
    "empty": {"type": "http"},
    "wrong": {"url": "ftp://example.com/mcp"},
    "text": "not a definition"
  }
}
''');

    expect(config.servers, isEmpty);
    expect(config.skipped, hasLength(3));
    expect(config.skipped[0], contains('no url'));
    expect(config.skipped[1], contains('ftp://example.com/mcp'));
  });

  test('what is not carried over is named, not dropped in silence', () {
    final config = readMcpConfig('''
{
  "mcpServers": {
    "weather": {
      "type": "sse",
      "url": "https://weather.example/sse",
      "headers": {"X-Api-Key": "k", "Authorization": "Bearer t"}
    }
  }
}
''');

    final server = config.servers.single;
    expect(server.token, 't');
    expect(server.note, contains('X-Api-Key'));
    expect(server.note, contains('SSE'));
  });

  test('text that is not a configuration is refused', () {
    expect(() => readMcpConfig('nope'), throwsFormatException);
    expect(() => readMcpConfig('[1, 2]'), throwsFormatException);
    expect(() => readMcpConfig('{}'), throwsFormatException);
    expect(() => readMcpConfig('{"mcpServers": []}'), throwsFormatException);
    expect(
      () => readMcpConfig('{"mcpServers": {}}'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('names no MCP servers'),
        ),
      ),
    );
  });
}
