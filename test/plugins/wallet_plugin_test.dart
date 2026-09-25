import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/plugins/wallet_plugin.dart';

import 'solar_test_support.dart';

/// One wallet as the API returns it, with the fields the projection reads and
/// the ones it must ignore.
Map<String, dynamic> walletJson({
  String id = 'w1',
  String name = 'Personal Wallet',
  bool isPrimary = true,
  String? publicId = 'sn-wallet-7',
  List<Map<String, dynamic>>? pockets,
}) => {
  'id': id,
  'name': name,
  'is_primary': isPrimary,
  'public_id': publicId,
  'pockets': pockets ?? [pocketJson(currency: 'CNY', amount: 12.5)],
  'account_id': 'acc-1',
  'account': null,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-09-01T00:00:00Z',
  'deleted_at': null,
};

/// One currency pocket as the API returns it.
Map<String, dynamic> pocketJson({
  String currency = 'CNY',
  double amount = 0,
  double? held,
}) => {
  'id': 'pocket-$currency',
  'currency': currency,
  'amount': amount,
  'held_amount': held,
  'wallet_id': 'w1',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-09-01T00:00:00Z',
  'deleted_at': null,
};

/// One period's statistics as the API returns them.
Map<String, dynamic> statsJson({
  Map<String, double> income = const {},
  Map<String, double> outgoing = const {},
}) => {
  'period_begin': '2026-09-01T00:00:00Z',
  'period_end': '2026-09-26T00:00:00Z',
  'total_transactions': 12,
  'total_orders': 2,
  'total_income': 300.0,
  'total_outgoing': 120.5,
  'sum': 179.5,
  'income_categories': income,
  'outgoing_categories': outgoing,
};

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

  test('read_wallet projects the wallet and the balance in each pocket', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets': walletJson(
        pockets: [
          pocketJson(currency: 'CNY', amount: 12.5),
          pocketJson(currency: 'SOLAR', amount: 900, held: 100),
        ],
      ),
    });

    final result = await run(adapter, 'read_wallet', {});

    expect(adapter.request('GET', '/wallet/wallets').method, 'GET');
    expect(result['wallet'], {
      'id': 'w1',
      'name': 'Personal Wallet',
      'is_default': true,
      'public_id_enabled': true,
      'pockets': [
        {'currency': 'CNY', 'balance': 12.5},
        {'currency': 'SOLAR', 'balance': 900.0, 'held': 100.0, 'available': 800.0},
      ],
    });
  });

  test('read_wallet answers that there is no wallet, without a second call', () async {
    final adapter = SolarStubAdapter(
      {'GET /wallet/wallets': {'message': 'no wallet'}},
      statuses: {'GET /wallet/wallets': 404},
    );

    final result = await run(adapter, 'read_wallet', {});

    expect(result, {'wallet': null});
    expect(adapter.requests, hasLength(1));
  });

  test('wallet_stats reports the period totals and omits empty breakdowns', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets/stats': statsJson(
        outgoing: {'subscription': 120.5},
      ),
    });

    final result = await run(adapter, 'wallet_stats', {});

    expect(adapter.request('GET', '/wallet/wallets/stats').method, 'GET');
    expect(result, {
      'period_begin': '2026-09-01T00:00:00Z',
      'period_end': '2026-09-26T00:00:00Z',
      'transactions': 12,
      'orders': 2,
      'income': 300.0,
      'outgoing': 120.5,
      'net': 179.5,
      'outgoing_by_category': {'subscription': 120.5},
    });
    expect(result, isNot(contains('income_by_category')));
  });

  test('a period that moved money in both directions keeps both breakdowns', () async {
    final adapter = SolarStubAdapter({
      'GET /wallet/wallets/stats': statsJson(
        income: {'gift': 300.0},
        outgoing: {'subscription': 120.5},
      ),
    });

    final result = await run(adapter, 'wallet_stats', {});

    expect(result['income_by_category'], {'gift': 300.0});
    expect(result['outgoing_by_category'], {'subscription': 120.5});
  });

  test('an expired session reads as something to renew, not as a status code', () async {
    final adapter = SolarStubAdapter(
      {'GET /wallet/wallets': {'message': 'token expired'}},
      statuses: {'GET /wallet/wallets': 401},
    );

    final result = await run(adapter, 'read_wallet', {});

    expect(result['error'], contains('not signed in'));
    expect(result['error'], contains('token expired'));
  });

  test('wallet_stats reports a refused request rather than throwing', () async {
    final adapter = SolarStubAdapter(
      {'GET /wallet/wallets/stats': {'message': 'scope wallet.read is missing'}},
      statuses: {'GET /wallet/wallets/stats': 403},
    );

    final result = await run(adapter, 'wallet_stats', {});

    expect(result['error'], contains('not allowed'));
    expect(result['error'], contains('scope wallet.read is missing'));
  });

  test('the plugin cannot move money, and says so to the user and the model', () {
    expect(plugin.id, 'wallet');
    expect(plugin.label, 'Wallet');
    expect(plugin.onDemand, isTrue);
    expect(plugin.enabledByDefault, isFalse);
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
