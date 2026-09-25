/// The user's Solar Network wallet: what it holds, and what moved through it.
///
/// Read-only, and the boundary is load-bearing. Moving money on Solar Network
/// is authorised by the user's local payment PIN, which this app does not hold
/// and must never ask for — so there is no transfer, order, gift or
/// subscription tool here, and none should be added. A plugin that offered one
/// would have to collect a PIN the app is not entitled to see, and the model
/// would learn to ask the user for it. Reading a balance and asking the user
/// to spend it in the app is the whole of what this grant covers.
///
/// On demand: the companion needs a balance rarely, and a user who leaves the
/// switch off should not pay for the definitions on every run.
library;

import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/local_tool.dart';
import 'package:persynth/plugins/plugin.dart';
import 'package:persynth/plugins/solar_support.dart';

class WalletPlugin extends SnPlugin {
  const WalletPlugin();

  @override
  String get id => 'wallet';

  @override
  String get label => 'Wallet';

  @override
  String get description =>
      'Reads the user\'s Solar Network wallet balance and statistics. It '
      'cannot move money.';

  @override
  String get summary => 'Read the wallet balance and statistics';

  @override
  bool get onDemand => true;

  /// The balance the server's `list_wallets` reads.
  ///
  /// Not claimed: `list_orders`, which is an order history these tools do not
  /// answer.
  @override
  Map<String, String> get overrides => const {'list_wallets': 'read_wallet'};

  @override
  List<SnLocalTool> buildTools(SnPluginContext context) {
    final wallet = context.solar.wallet;
    return [
      SnLocalTool(
        name: 'read_wallet',
        description:
            'The user\'s Solar Network wallet and what each of its currency '
            'pockets holds. Answers that the user has no wallet when that is '
            'the case. It can read a balance; it cannot move funds.',
        parameters: const {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        execute: (arguments) => solarToolResult(() async {
          final found = await wallet.getWallet();
          // No wallet is a fact about the account, not a failed request, and
          // the model has to be able to say so without reporting an error.
          return {'wallet': found == null ? null : _wallet(found)};
        }),
      ),
      SnLocalTool(
        name: 'wallet_stats',
        description:
            'How the user\'s Solar Network wallet moved over a recent period: '
            'the number of transactions and orders, what came in, what went '
            'out and the net, with a breakdown by category when the period had '
            'any. It can read history; it cannot move funds.',
        parameters: const {
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        execute: (arguments) => solarToolResult(
          () async => _stats(await wallet.getWalletStats()),
        ),
      ),
    ];
  }

  @override
  List<String> systemPrompt(SnPluginContext context) => const [
    'The user\'s Solar Network wallet tools are loaded: local_read_wallet and '
    'local_wallet_stats. They run as the signed-in user on their own '
    'connection.',
    'Those tools can see a balance and what moved through it; they cannot '
    'spend. Moving money on Solar Network needs the user\'s payment PIN, which '
    'this app does not hold and must never ask them for. When the user wants to '
    'transfer funds, buy or subscribe to something, say that it has to be done '
    'in the app, and never promise to carry it out from here.',
  ];
}

/// One wallet projected to what an answer needs.
///
/// A wallet embeds its account and every pocket's timestamps; serializing it
/// whole would spend the context window on bookkeeping. The balance lives in
/// the pockets, one per currency, so it is kept in full while the rest of the
/// record is dropped.
Map<String, dynamic> _wallet(SnWallet wallet) => {
  'id': wallet.id,
  'name': wallet.name,
  'is_default': wallet.isPrimary,
  // Null unless the user turned the public id on; the app never sets it.
  'public_id_enabled': wallet.publicId != null,
  'pockets': wallet.pockets.map(_pocket).toList(),
};

/// One currency pocket, as the model reads a balance.
///
/// `available` is omitted while nothing is held against the balance, because
/// then it repeats `balance` and a second identical number invites the model
/// to treat the two as different amounts.
Map<String, dynamic> _pocket(SnWalletPocket pocket) {
  final held = pocket.heldAmount;
  return {
    'currency': pocket.currency,
    'balance': pocket.amount,
    if (held > 0) 'held': held,
    if (held > 0) 'available': pocket.availableAmount,
  };
}

/// One period's totals, as the model reads them.
///
/// The category maps are sparse — most periods move money in one or two
/// categories — so an empty one is left out rather than sent as `{}`.
Map<String, dynamic> _stats(SnWalletStats stats) => {
  'period_begin': solarStamp(stats.periodBegin),
  'period_end': solarStamp(stats.periodEnd),
  'transactions': stats.totalTransactions,
  'orders': stats.totalOrders,
  'income': stats.totalIncome,
  'outgoing': stats.totalOutgoing,
  'net': stats.sum,
  if (stats.incomeCategories.isNotEmpty)
    'income_by_category': stats.incomeCategories,
  if (stats.outgoingCategories.isNotEmpty)
    'outgoing_by_category': stats.outgoingCategories,
};
