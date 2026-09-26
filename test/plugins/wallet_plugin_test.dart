import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/wallet_plugin.dart';

import 'solar_test_support.dart';

/// One wallet as the wallet service returns it: the fields the projection
/// reads, plus the embedded records and timestamps it must ignore.
Map<String, dynamic> walletJson({
  String? id = 'w1',
  String? name = 'Personal Wallet',
  bool isPrimary = true,
  String? publicId = 'sn-wallet-7',
  List<Map<String, dynamic>>? pockets,
}) => {
  'id': id,
  'name': name,
  'is_primary': isPrimary,
  'is_default': isPrimary,
  'public_id': publicId,
  'pockets': pockets ?? [pocketJson()],
  'account_id': 'acc-1',
  'realm_id': null,
  'account': null,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-09-01T00:00:00Z',
  'deleted_at': null,
};

/// One currency pocket as the wallet service returns it.
Map<String, dynamic> pocketJson({
  String? currency = 'CNY',
  num amount = 0,
  num held = 0,
}) => {
  'id': 'pocket-$currency',
  'currency': currency,
  'amount': amount,
  'held_amount': held,
  // A computed property the model serializes alongside the stored ones.
  'available_amount': amount - held,
  'wallet_id': 'w1',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-09-01T00:00:00Z',
  'deleted_at': null,
};

/// One period's statistics as the wallet service returns them.
///
/// The totals are derived from the category maps server-side, so the stub
/// derives them the same way unless a test overrides one to report a period
/// whose totals did not arrive.
Map<String, dynamic> statsJson({
  Map<String, num> income = const {},
  Map<String, num> outgoing = const {},
  num? totalIncome,
  num? totalOutgoing,
  int? transactions = 12,
  int? orders = 2,
}) {
  final inTotal = totalIncome ?? income.values.fold<num>(0, (a, b) => a + b);
  final outTotal = totalOutgoing ?? outgoing.values.fold<num>(0, (a, b) => a + b);
  return {
    'period_begin': '2026-09-01T00:00:00Z',
    'period_end': '2026-09-26T00:00:00Z',
    'total_transactions': transactions,
    'total_orders': orders,
    'income_categories': income,
    'outgoing_categories': outgoing,
    'total_income': inTotal,
    'total_outgoing': outTotal,
    'sum': inTotal - outTotal,
  };
}

/// The plugin builds its tools once per context, so each test builds the set
/// over its own adapter and reaches for the tool it is about.
void main() {
  const plugin = WalletPlugin();

  Future<Map<String, dynamic>> run(
    SolarStubAdapter adapter,
    String tool,
    Map<String, dynamic> arguments,
  ) async {
    final built = solarTool(
      plugin.buildTools(solarContext(solarDio(adapter))),
      tool,
    );
    return solarResult(await built.execute(arguments));
  }

  test('read_wallet asks the wallet route and projects a balance per pocket', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets': walletJson(
        pockets: [
          pocketJson(currency: 'CNY', amount: 12.5),
          pocketJson(currency: 'SOLAR', amount: 900, held: 100),
        ],
      ),
    });

    final result = await run(adapter, 'read_wallet', {});

    final request = adapter.request('GET', '/wallet/wallets');
    expect(request.method, 'GET');
    expect(request.queryParameters, isEmpty);
    expect(result['wallet'], {
      'id': 'w1',
      'name': 'Personal Wallet',
      'is_default': true,
      'public_id_enabled': true,
      'pockets': [
        {'currency': 'CNY', 'balance': 12.5},
        // Nothing is held against the CNY balance, so `available` would only
        // repeat it and is left out.
        {'currency': 'SOLAR', 'balance': 900.0, 'held': 100.0, 'available': 800.0},
      ],
    });
  });

  test('read_wallet answers that the user has no wallet instead of an error', () async {
    final adapter = SolarStubAdapter(
      {'GET /wallet/wallets': {'message': 'Wallet was not found, please create one first.'}},
      statuses: {'GET /wallet/wallets': 404},
    );

    final result = await run(adapter, 'read_wallet', {});

    // No wallet is a fact about the account, not a failed request: the model
    // gets to say so, and nothing makes a second call looking for it.
    expect(result, {'wallet': null});
    expect(adapter.requests, hasLength(1));
  });

  test('a wallet that holds no pockets answers an empty list, not an error', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets': walletJson(pockets: []),
    });

    final result = await run(adapter, 'read_wallet', {});

    expect(result, isNot(contains('error')));
    expect(result['wallet']['pockets'], isEmpty);
  });

  test('a pocket that omits its held and available amounts still reads', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets': {
        'id': 'w1',
        'pockets': [
          {'currency': 'SOLAR', 'amount': 900, 'held_amount': 100},
          {'currency': 'CNY', 'amount': 0, 'held_amount': null},
        ],
      },
    });

    final result = await run(adapter, 'read_wallet', {});

    expect(result['wallet']['pockets'], [
      // `available_amount` was not sent; what the user can spend is the
      // difference, not a null.
      {'currency': 'SOLAR', 'balance': 900, 'held': 100, 'available': 800},
      // A null hold is no hold, and a zero balance is an answer.
      {'currency': 'CNY', 'balance': 0},
    ]);
  });

  test('wallet_stats asks the period route for points and reports its totals', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets/stats': statsJson(outgoing: {'subscription': 120.5}),
    });

    final result = await run(adapter, 'wallet_stats', {});

    // Both parameters are named on the wire: the period is the 30 days the
    // tool describes, and the currency is spelled out so the answer cannot
    // silently follow a server default somewhere else.
    expect(adapter.request('GET', '/wallet/wallets/stats').queryParameters, {
      'period': 30,
      'currencies': 'points',
    });
    expect(result, {
      'period_begin': '2026-09-01T00:00:00Z',
      'period_end': '2026-09-26T00:00:00Z',
      'transactions': 12,
      'orders': 2,
      // Nothing came in, and that is worth saying: a total of zero is an
      // answer, so it is kept rather than compacted away.
      'income': 0,
      'outgoing': 120.5,
      'net': -120.5,
      'outgoing_by_category': {'subscription': 120.5},
    });
    // An empty breakdown is left out rather than sent as `{}`.
    expect(result, isNot(contains('income_by_category')));
  });

  test('a period that moved money both ways keeps both breakdowns', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets/stats': statsJson(
        income: {'gift': 300.0},
        outgoing: {'subscription': 120.5},
      ),
    });

    final result = await run(adapter, 'wallet_stats', {});

    expect(result['income'], 300.0);
    expect(result['income_by_category'], {'gift': 300.0});
    expect(result['outgoing_by_category'], {'subscription': 120.5});
    expect(result['net'], 179.5);
  });

  test('a payload the wire barely fills in still answers', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets': {'id': 'w1'},
      'GET /wallet/wallets/stats': {
        'period_begin': null,
        'period_end': null,
        'total_transactions': null,
        'total_orders': null,
        'total_income': null,
        'total_outgoing': null,
        'sum': null,
        'income_categories': {},
        'outgoing_categories': {},
      },
    });

    final wallet = await run(adapter, 'read_wallet', {});
    final stats = await run(adapter, 'wallet_stats', {});

    // Every absent key is a missing value: a wallet with no pockets and no
    // reported totals is an answer, and reading it never throws.
    expect(wallet, isNot(contains('error')));
    expect(wallet['wallet']['id'], 'w1');
    expect(wallet['wallet']['pockets'], isEmpty);
    expect(wallet['wallet']['is_default'], isFalse);
    expect(stats, isNot(contains('error')));
    expect(stats, isEmpty);
  });

  test('a refused request is reported as an error, not thrown', () async {
    final expired = SolarStubAdapter(
      {'GET /wallet/wallets': {'message': 'token expired'}},
      statuses: {'GET /wallet/wallets': 401},
    );

    final signedOut = await run(expired, 'read_wallet', {});

    expect(signedOut['error'], contains('not signed in'));
    expect(signedOut['error'], contains('token expired'));

    final scoped = SolarStubAdapter(
      {'GET /wallet/wallets/stats': {'message': 'scope wallet.read is missing'}},
      statuses: {'GET /wallet/wallets/stats': 403},
    );

    final refused = await run(scoped, 'wallet_stats', {});

    expect(refused['error'], contains('not allowed'));
    expect(refused['error'], contains('scope wallet.read is missing'));
  });

  test('the plugin cannot move money, and says so to the user and the model', () {
    expect(plugin.id, 'wallet');
    expect(plugin.label, 'Wallet');
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
    expect(plugin.overrides, {'list_wallets': 'read_wallet'});
    expect(plugin.description, contains('cannot move money'));

    final tools = plugin.buildTools(solarContext(solarDio(SolarStubAdapter({}))));
    expect(tools.map((tool) => tool.name), ['read_wallet', 'wallet_stats']);

    final prompt = plugin.systemPrompt(
      solarContext(solarDio(SolarStubAdapter({}))),
    );
    // The model must not offer to move funds, and must not ask for the PIN
    // that would let it: the app has no way to carry such a call out.
    expect(prompt, anyElement(contains('cannot spend')));
    expect(prompt, anyElement(contains('payment PIN')));
    expect(prompt, anyElement(contains('in the app')));
  });
}
