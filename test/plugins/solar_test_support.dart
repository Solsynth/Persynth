/// Test plumbing shared by the Solar-backed plugin tests.
///
/// The plugin bodies are thin, but they are thin *over the wire*: what is
/// worth asserting is the request that leaves and the projection that comes
/// back. So a stub serves canned JSON per `METHOD /path`, records every
/// request, and reports an unmatched path as a 404 rather than a bare failure
/// — a typo in a path then fails as the missing stub it is.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';

/// The gateway the app talks to, as the default server URL does.
///
/// The paths the tools call are checked against the live gateway by
/// `tool/verify_solar_routes.dart`; these tests check that each tool calls the
/// path it is supposed to.
const String testSolarBaseUrl = 'https://api.solian.app';

/// Serves one canned JSON body per `METHOD /path` and records the requests.
class SolarStubAdapter implements HttpClientAdapter {
  SolarStubAdapter(this.routes, {Map<String, int>? totals, Map<String, int>? statuses})
    : totals = totals ?? const {},
      statuses = statuses ?? const {};

  /// `'GET /sphere/timeline/home'` to the JSON body to answer with.
  final Map<String, Object?> routes;

  /// The `X-Total` header the SDK reads, keyed the same way.
  final Map<String, int> totals;

  /// The status to answer a stubbed route with, where 200 is not the point.
  final Map<String, int> statuses;

  final List<RequestOptions> requests = [];

  /// The request recorded for [method] and [path].
  RequestOptions request(String method, String path) => requests.firstWhere(
    (options) => options.method == method && options.path == path,
    orElse: () => throw StateError(
      'no $method $path was made; saw '
      '${requests.map((options) => '${options.method} ${options.path}').join(', ')}',
    ),
  );

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.path}';
    final headers = <String, List<String>>{
      Headers.contentTypeHeader: ['application/json'],
    };
    final total = totals[key];
    if (total != null) headers['X-Total'] = ['$total'];
    if (!routes.containsKey(key)) {
      return ResponseBody.fromString(
        jsonEncode({'message': 'no stub for $key'}),
        404,
        headers: headers,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(routes[key]),
      statuses[key] ?? 200,
      headers: headers,
    );
  }
}

/// A client over [adapter], with the base URL the app uses.
Dio solarDio(SolarStubAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: testSolarBaseUrl));
  dio.httpClientAdapter = adapter;
  return dio;
}

/// A context whose Solar connection is [dio] and whose other dependencies are
/// present but never reached — a plugin that touches them in a test about
/// Solar Network is a bug the test should surface.
SnPluginContext solarContext(Dio dio) => SnPluginContext(api: dio, http: dio);

/// A listing as the gateway answers one: an envelope with the items inside.
///
/// The timeline is the endpoint that does this, and a tool reading it has to
/// cope with both shapes.
Map<String, dynamic> pageJson(List<Object?> items) => {
  'items': items,
  'next_cursor': null,
  'mode': 'personalized',
};

/// The one tool named [name] in [tools].
SnLocalTool solarTool(List<SnLocalTool> tools, String name) => tools.firstWhere(
  (tool) => tool.name == name,
  orElse: () => throw StateError(
    'no tool named $name; have ${tools.map((tool) => tool.name).join(', ')}',
  ),
);

/// Decodes the JSON a tool body returned.
Map<String, dynamic> solarResult(String result) =>
    jsonDecode(result) as Map<String, dynamic>;

/// One post as the API returns it, for stubs to build on.
Map<String, dynamic> postJson({
  required String id,
  String? content = 'hello',
  String? publisherName = 'littleSheep',
  String? publisherNick = 'Little Sheep',
  int replies = 0,
}) => {
  'id': id,
  'content': content,
  'published_at': '2026-09-20T10:00:00.000Z',
  'replies_count': replies,
  'publisher': {
    'id': 'pub-$publisherName',
    'name': publisherName,
    'nick': publisherNick,
  },
};
