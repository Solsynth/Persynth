import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';
import 'package:persynth/plugins/plugin_registry.dart';
import 'package:persynth/plugins/web_tools_plugin.dart';
import 'package:persynth/theme/app_theme.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ai_console_tabs.g.dart';

// ---------------------------------------------------------------------------
// Models — local client-side mirrors of the FloatLand personality backend
// (/personality). Kept dependency-free (plain fromJson) since these are not
// part of the typed solar_network_sdk surface.
//
// Agents and their provider live in `lib/personality/personality_api.dart`
// alongside the conversation/run client the pet page uses.
// ---------------------------------------------------------------------------

class SnPersonalityRunUsage {
  final String used;
  final String? max;
  const SnPersonalityRunUsage({required this.used, this.max});

  factory SnPersonalityRunUsage.fromJson(Map<String, dynamic> json) =>
      SnPersonalityRunUsage(
        used: (json['used'] ?? '0').toString(),
        max: json['max']?.toString(),
      );
}

/// What the account has consumed in one interval, per currency. A null
/// [SnPersonalityRunUsage.max] is "no limit configured", not "unknown".
class SnPersonalityBillingUsage {
  final Map<String, SnPersonalityRunUsage> hourlyUsage;
  final Map<String, SnPersonalityRunUsage> dailyUsage;

  const SnPersonalityBillingUsage({
    this.hourlyUsage = const {},
    this.dailyUsage = const {},
  });

  factory SnPersonalityBillingUsage.fromJson(Map<String, dynamic> json) {
    Map<String, SnPersonalityRunUsage> parseMap(dynamic m) {
      if (m is! Map) return const {};
      return {
        for (final e in m.entries)
          e.key.toString(): SnPersonalityRunUsage.fromJson(
            e.value as Map<String, dynamic>,
          ),
      };
    }

    return SnPersonalityBillingUsage(
      hourlyUsage: parseMap(json['hourly_usage']),
      dailyUsage: parseMap(json['daily_usage']),
    );
  }
}

class SnPersonalityBilling {
  final String? spendingQuota;
  final bool blacklisted;
  final SnPersonalityBillingUsage usage;

  const SnPersonalityBilling({
    this.spendingQuota,
    this.blacklisted = false,
    required this.usage,
  });

  factory SnPersonalityBilling.fromJson(Map<String, dynamic> json) =>
      SnPersonalityBilling(
        spendingQuota: json['spending_quota']?.toString(),
        blacklisted: json['blacklisted'] is bool ? json['blacklisted'] : false,
        usage: SnPersonalityBillingUsage.fromJson(
          json['usage'] as Map<String, dynamic>? ?? const {},
        ),
      );
}

class SnPersonalityModelPricing {
  final String? currency;
  final String? input;
  final String? output;
  const SnPersonalityModelPricing({this.currency, this.input, this.output});

  factory SnPersonalityModelPricing.fromJson(Map<String, dynamic> json) =>
      SnPersonalityModelPricing(
        currency: json['currency']?.toString(),
        input: json['input']?.toString(),
        output: json['output']?.toString(),
      );
}

class SnPersonalityModel {
  final String id;
  final String provider;
  final String name;
  final String? type;
  final List<String> modalities;
  final SnPersonalityModelPricing? pricing;

  const SnPersonalityModel({
    required this.id,
    required this.provider,
    required this.name,
    this.type,
    this.modalities = const [],
    this.pricing,
  });

  factory SnPersonalityModel.fromJson(Map<String, dynamic> json) =>
      SnPersonalityModel(
        id: json['id'] as String,
        provider: json['provider'] as String,
        name: json['name'] as String,
        type: json['type']?.toString(),
        modalities:
            (json['modalities'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        pricing: json['pricing'] is Map
            ? SnPersonalityModelPricing.fromJson(json['pricing'])
            : null,
      );
}

class SnPersonalityCredential {
  final String id;
  final String name;
  final String tokenPrefix;
  final List<String> agentIds;
  final List<String> providers;
  final List<String> models;
  final String usageLimit;
  final String usageUsed;
  final String usageCurrency;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SnPersonalityCredential({
    required this.id,
    required this.name,
    required this.tokenPrefix,
    this.agentIds = const [],
    this.providers = const [],
    this.models = const [],
    required this.usageLimit,
    required this.usageUsed,
    required this.usageCurrency,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  factory SnPersonalityCredential.fromJson(Map<String, dynamic> json) =>
      SnPersonalityCredential(
        id: json['id'] as String,
        name: json['name'] as String,
        tokenPrefix: json['token_prefix'] as String,
        agentIds:
            (json['agent_ids'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        providers:
            (json['providers'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        models:
            (json['models'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        usageLimit: (json['usage_limit'] ?? '0').toString(),
        usageUsed: (json['usage_used'] ?? '0').toString(),
        usageCurrency: json['usage_currency']?.toString() ?? 'USD',
        enabled: json['enabled'] is bool ? json['enabled'] : true,
        createdAt: json['created_at'] is String
            ? DateTime.parse(json['created_at'])
            : DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt: json['updated_at'] is String
            ? DateTime.parse(json['updated_at'])
            : DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class SnPersonalityCredentialCreated {
  final SnPersonalityCredential credential;
  final String token;

  const SnPersonalityCredentialCreated({
    required this.credential,
    required this.token,
  });

  factory SnPersonalityCredentialCreated.fromJson(Map<String, dynamic> json) =>
      SnPersonalityCredentialCreated(
        credential: SnPersonalityCredential.fromJson(
          json['credential'] as Map<String, dynamic>,
        ),
        token: json['token'] as String,
      );
}

// ---------------------------------------------------------------------------
// Audit — the billing ledger, and where searches run
// ---------------------------------------------------------------------------

/// One charge in the account's billing ledger, as the audit reads it.
///
/// A row states both what was consumed ([action], [model], the token counts and
/// [originalAmount]) and which call consumed it ([surface], [credentialId],
/// [clientIp], [deviceId], [userAgent]). [threadId] and [agentId] come from the
/// run the charge belongs to and are empty for a charge that has no run.
class SnLedgerEntry {
  final String id;
  final String action;
  final String surface;
  final String model;
  final String currency;
  final String? threadId;
  final String? agentId;
  final String clientIp;
  final String deviceId;
  final int inputTokens;
  final int outputTokens;

  /// The price the usage was incurred at. The row's `amount` shrinks as a
  /// partial payment settles it, so an audit reads this one.
  final String originalAmount;

  final DateTime? createdAt;

  const SnLedgerEntry({
    required this.id,
    required this.action,
    required this.surface,
    required this.model,
    required this.currency,
    this.threadId,
    this.agentId,
    this.clientIp = '',
    this.deviceId = '',
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.originalAmount = '0',
    this.createdAt,
  });

  factory SnLedgerEntry.fromJson(Map<String, dynamic> json) => SnLedgerEntry(
    id: json['id']?.toString() ?? '',
    action: json['action']?.toString() ?? '',
    surface: json['surface']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    currency: json['currency']?.toString() ?? '',
    threadId: _optionalText(json['thread_id']),
    agentId: _optionalText(json['agent_id']),
    clientIp: json['client_ip']?.toString() ?? '',
    deviceId: json['device_id']?.toString() ?? '',
    inputTokens: _jsonInt(json['input_tokens']),
    outputTokens: _jsonInt(json['output_tokens']),
    originalAmount: json['original_amount']?.toString() ?? '0',
    createdAt: DateTime.tryParse(
      json['created_at']?.toString() ?? '',
    )?.toLocal(),
  );
}

/// One line of the audit's breakdown: how much a single key consumed.
///
/// Every bucket is single-currency, because summing different currencies means
/// nothing; a key that spans currencies yields one bucket per currency.
class SnLedgerBucket {
  final String key;
  final String currency;
  final int entries;
  final int inputTokens;
  final int outputTokens;
  final String amount;

  const SnLedgerBucket({
    required this.key,
    required this.currency,
    this.entries = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.amount = '0',
  });

  factory SnLedgerBucket.fromJson(Map<String, dynamic> json) =>
      SnLedgerBucket(
        key: json['key']?.toString() ?? '',
        currency: json['currency']?.toString() ?? '',
        entries: _jsonInt(json['entries']),
        inputTokens: _jsonInt(json['input_tokens']),
        outputTokens: _jsonInt(json['output_tokens']),
        amount: json['amount']?.toString() ?? '0',
      );

  static List<SnLedgerBucket> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw.whereType<Map>())
        SnLedgerBucket.fromJson(Map<String, dynamic>.from(entry)),
    ];
  }
}

/// What the account consumed in the window, split along every audit dimension
/// at once — which is what lets the reader find the call that spent the money
/// without knowing which dimension it belongs to.
class SnLedgerSummary {
  final int entries;
  final List<SnLedgerBucket> byAction;
  final List<SnLedgerBucket> bySurface;
  final List<SnLedgerBucket> byModel;
  final List<SnLedgerBucket> byCurrency;
  final List<SnLedgerBucket> byClientIp;
  final List<SnLedgerBucket> byDeviceId;
  final List<SnLedgerBucket> byCredential;
  final List<SnLedgerBucket> byDay;

  const SnLedgerSummary({
    this.entries = 0,
    this.byAction = const [],
    this.bySurface = const [],
    this.byModel = const [],
    this.byCurrency = const [],
    this.byClientIp = const [],
    this.byDeviceId = const [],
    this.byCredential = const [],
    this.byDay = const [],
  });

  factory SnLedgerSummary.fromJson(Map<String, dynamic> json) =>
      SnLedgerSummary(
        entries: _jsonInt(json['entries']),
        byAction: SnLedgerBucket.listFrom(json['by_action']),
        bySurface: SnLedgerBucket.listFrom(json['by_surface']),
        byModel: SnLedgerBucket.listFrom(json['by_model']),
        byCurrency: SnLedgerBucket.listFrom(json['by_currency']),
        byClientIp: SnLedgerBucket.listFrom(json['by_client_ip']),
        byDeviceId: SnLedgerBucket.listFrom(json['by_device_id']),
        byCredential: SnLedgerBucket.listFrom(json['by_credential']),
        byDay: SnLedgerBucket.listFrom(json['by_day']),
      );
}

/// One engine a search can be kept on, and what one query through it costs.
class SnWebSearchEngine {
  final String id;
  final String price;
  final bool metered;
  final bool free;

  const SnWebSearchEngine({
    required this.id,
    this.price = '',
    this.metered = false,
    this.free = false,
  });

  factory SnWebSearchEngine.fromJson(Map<String, dynamic> json) =>
      SnWebSearchEngine(
        id: json['id']?.toString() ?? '',
        price: json['price']?.toString() ?? '',
        metered: json['metered'] == true,
        free: json['free'] == true,
      );
}

class SnWebSearchCatalog {
  final String currency;
  final List<SnWebSearchEngine> engines;

  const SnWebSearchCatalog({this.currency = '', this.engines = const []});

  factory SnWebSearchCatalog.fromJson(Map<String, dynamic> json) =>
      SnWebSearchCatalog(
        currency: json['currency']?.toString() ?? '',
        engines: [
          for (final entry in (json['engines'] as List? ?? const []).whereType<Map>())
            SnWebSearchEngine.fromJson(Map<String, dynamic>.from(entry)),
        ],
      );
}

/// The account's chosen engine. Empty means the server's own order decides.
class SnWebSearchPreference {
  final String engine;
  final String currency;

  const SnWebSearchPreference({this.engine = '', this.currency = ''});

  factory SnWebSearchPreference.fromJson(Map<String, dynamic> json) =>
      SnWebSearchPreference(
        engine: json['engine']?.toString() ?? '',
        currency: json['currency']?.toString() ?? '',
      );
}

/// The engine choice as one read: the engines to choose between, and the one
/// this account is on.
class SnWebSearchChoice {
  final SnWebSearchCatalog catalog;
  final SnWebSearchPreference preference;

  const SnWebSearchChoice({required this.catalog, required this.preference});
}

/// What the audit is narrowed to: a rolling window, and at most one breakdown
/// key the reader tapped. Rolling rather than calendar days, because a charge
/// is metered when it happens, not at a day boundary.
class SnLedgerQuery {
  const SnLedgerQuery({this.days = 7, this.key, this.value});

  final int days;

  /// The breakdown dimension the reader narrowed to — `action`, `surface`,
  /// `device`, `ip` or `credential` — and the key within it.
  final String? key;
  final String? value;

  SnLedgerQuery narrowed(String key, String value) =>
      SnLedgerQuery(days: days, key: key, value: value);

  Map<String, String> toQueryParameters() => {
    'take': '50',
    'from': DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String(),
    if (key == 'action' && value != null) 'action': value!,
    if (key == 'surface' && value != null) 'surface': value!,
    if (key == 'device' && value != null) 'device_id': value!,
    if (key == 'ip' && value != null) 'client_ip': value!,
    if (key == 'credential' && value != null) 'credential_id': value!,
  };

  @override
  bool operator ==(Object other) =>
      other is SnLedgerQuery &&
      other.days == days &&
      other.key == key &&
      other.value == value;

  @override
  int get hashCode => Object.hash(days, key, value);
}

String? _optionalText(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

int _jsonInt(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

/// The rolling windows the audit offers.
const _ledgerWindows = <int, String>{1: '24 hours', 7: '7 days', 30: '30 days'};

/// How many rows of a breakdown are listed before the rest are counted up.
const _kBreakdownRows = 4;

/// The audit's name for a ledger action: the ledger's own vocabulary is
/// machine-shaped, and a reader looking for what spent the money is better
/// served by "Reply" and "Search · tavily" than by "generation" and
/// "web_search/tavily". The raw value is still what a filter sends.
String _actionLabel(String action) {
  final parts = action.split('/');
  switch (parts.first) {
    case 'generation':
      return 'Reply';
    case 'web_search':
      final engine = parts.length > 1 ? parts[1].trim() : '';
      final label = parts.length > 2 && parts[2] == 'tokens'
          ? 'Search tokens'
          : 'Search';
      return engine.isEmpty ? label : '$label · $engine';
    default:
      return action.isEmpty ? 'Charge' : action;
  }
}

/// A ledger amount as a reader reads it: two decimals, with a charge too small
/// to show kept visible rather than rounded to a free-looking zero.
String _formatAmount(String raw) {
  final value = double.tryParse(raw.trim()) ?? 0;
  if (value == 0) return '0';
  if (value.abs() < 0.01) return '<0.01';
  return value.toStringAsFixed(2);
}

/// What one query through [engine] costs, in the catalog's currency.
String _engineCost(SnWebSearchEngine engine, String currency) {
  if (engine.free) return 'free';
  final unit = _localizeCurrency(currency).toLowerCase();
  final parts = <String>[
    if (engine.price.isNotEmpty) '${_formatAmount(engine.price)} $unit a search',
    if (engine.metered) 'provider tokens billed',
  ];
  return parts.isEmpty ? 'free' : parts.join(' · ');
}

String _ledgerDimensionLabel(String key) {
  switch (key) {
    case 'action':
      return 'Action';
    case 'surface':
      return 'Endpoint';
    case 'device':
      return 'Device';
    case 'ip':
      return 'Address';
    case 'credential':
      return 'Credential';
    default:
      return key;
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

@riverpod
Future<List<SnPersonalityModel>> personalityModels(Ref ref) async {
  final dio = ref.read(personalityApiClientProvider);
  final resp = await dio.get('/personality/models');
  final data = resp.data;
  if (data is List) {
    return [
      for (final e in data)
        SnPersonalityModel.fromJson(e as Map<String, dynamic>),
    ];
  }
  return const [];
}

@riverpod
Future<SnPersonalityBilling> personalityBilling(Ref ref) async {
  final dio = ref.read(personalityApiClientProvider);
  final resp = await dio.get('/personality/billing/me');
  return SnPersonalityBilling.fromJson(resp.data as Map<String, dynamic>);
}

@riverpod
Future<List<SnPersonalityCredential>> personalityCredentials(Ref ref) async {
  final dio = ref.read(personalityApiClientProvider);
  final resp = await dio.get('/personality/openai/credentials');
  final data = resp.data;
  final list = data is Map ? data['data'] : null;
  if (list is List) {
    return [
      for (final e in list)
        SnPersonalityCredential.fromJson(e as Map<String, dynamic>),
    ];
  }
  return const [];
}

/// The account's charges in the window, newest first, narrowed by the reader's
/// chosen breakdown key.
@riverpod
Future<List<SnLedgerEntry>> personalityBillingLedger(
  Ref ref,
  SnLedgerQuery query,
) async {
  final dio = ref.read(personalityApiClientProvider);
  final resp = await dio.get(
    '/personality/billing/me/ledger',
    queryParameters: query.toQueryParameters(),
  );
  final data = resp.data;
  if (data is! List) return const [];
  return [
    for (final entry in data.whereType<Map>())
      SnLedgerEntry.fromJson(Map<String, dynamic>.from(entry)),
  ];
}

/// The window's spend along every audit dimension. The reader's filter is
/// deliberately not part of this: the breakdown is the overview the filter is
/// chosen from, so narrowing the list must not narrow the breakdown with it.
@riverpod
Future<SnLedgerSummary> personalityLedgerSummary(
  Ref ref,
  SnLedgerQuery query,
) async {
  final dio = ref.read(personalityApiClientProvider);
  final resp = await dio.get(
    '/personality/billing/me/ledger/summary',
    queryParameters: query.toQueryParameters(),
  );
  return SnLedgerSummary.fromJson(Map<String, dynamic>.from(resp.data as Map));
}

/// The engines a search can be kept on, and the one this account is on, read
/// together because the picker needs both to draw a single choice.
@riverpod
Future<SnWebSearchChoice> personalitySearchChoice(Ref ref) async {
  final dio = ref.read(personalityApiClientProvider);
  final responses = await Future.wait([
    dio.get('/personality/web/search/engines'),
    dio.get('/personality/web/search/preference'),
  ]);
  return SnWebSearchChoice(
    catalog: SnWebSearchCatalog.fromJson(
      Map<String, dynamic>.from(responses[0].data as Map),
    ),
    preference: SnWebSearchPreference.fromJson(
      Map<String, dynamic>.from(responses[1].data as Map),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tabs — hosted by the settings page
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  final String label;
  final String value;
  final Widget? trailing;
  const _KeyValue(this.label, this.value, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        trailing ?? const SizedBox.shrink(),
      ],
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({this.message = 'Nothing here yet.'});

  /// What the empty screen says. Defaults to the pass-through note, so a
  /// surface with something more useful to tell the reader can say it.
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class AiConsoleCatalogTab extends ConsumerWidget {
  const AiConsoleCatalogTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(personalityAgentsProvider);
    final models = ref.watch(personalityModelsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        spacing: 16,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('Agents'),
          agents.when(
            data: (list) {
              return Column(
                spacing: 8,
                children: [
                  for (final a in list) _AgentCard(agent: a),
                  if (list.isEmpty) const _EmptyNote(),
                ],
              );
            },
            error: (e, _) => _ResponseError(
              error: e,
              onRetry: () => ref.invalidate(personalityAgentsProvider),
            ),
            loading: () => const _ResponseLoading(),
          ),
          const _SectionTitle('Models'),
          models.when(
            data: (list) => Column(
              spacing: 8,
              children: [
                for (final m in list) _ModelCard(model: m),
                if (list.isEmpty) const _EmptyNote(),
              ],
            ),
            error: (e, _) => _ResponseError(
              error: e,
              onRetry: () => ref.invalidate(personalityModelsProvider),
            ),
            loading: () => const _ResponseLoading(),
          ),
        ],
      ),
    );
  }
}

class _AgentCard extends ConsumerWidget {
  final SnPersonalityAgent agent;
  const _AgentCard({required this.agent});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              children: [
                Icon(
                  agent.enabled ? Symbols.check_circle : Symbols.cancel,
                  color: agent.enabled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const Gap(8),
                Expanded(
                  child: Text(agent.name, style: theme.textTheme.titleMedium),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: agent.enabled
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    agent.enabled ? 'Enabled' : 'Disabled',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            if (agent.description != null)
              Text(agent.description!, style: theme.textTheme.bodySmall),
            if (agent.model != null) _KeyValue('Model', agent.model!),
            if (agent.abilities.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final ab in agent.abilities)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(ab),
                      labelStyle: theme.textTheme.labelSmall,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final SnPersonalityModel model;
  const _ModelCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pricing = model.pricing;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(model.name, style: theme.textTheme.titleMedium),
            _KeyValue('Provider', model.provider),
            if (model.type != null) _KeyValue('Type', model.type!),
            if (model.modalities.isNotEmpty)
              _KeyValue('Modalities', model.modalities.join(', ')),
            if (pricing != null)
              _KeyValue(
                'Pricing',
                '${pricing.input ?? '?'} / ${pricing.output ?? '?'}'
                    ' (${_localizeCurrency(pricing.currency ?? 'USD')})',
                trailing: Text(
                  'per 1K tokens',
                  style: theme.textTheme.labelSmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Localizes a wallet currency code (`points` → "Bits", `golds` → "Golds"),
/// like the payment overlay does. Unknown codes (e.g. `USD`) pass through.
const _currencyLabels = <String, String>{'points': 'Bits', 'golds': 'Golds'};

String _localizeCurrency(String currency) {
  if (currency.isEmpty) return currency;
  return _currencyLabels[currency.toLowerCase()] ?? currency;
}

class AiConsoleBillingTab extends HookConsumerWidget {
  const AiConsoleBillingTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billing = ref.watch(personalityBillingProvider);
    final quotaController = useTextEditingController();
    final quotaInitialized = useState(false);
    // Rebuilds on every keystroke, so the Save button follows what is typed
    // without a second listener.
    final quotaText = useValueListenable(quotaController).text.trim();

    return billing.when(
      data: (b) {
        if (!quotaInitialized.value) {
          quotaController.text = b.spendingQuota ?? '0';
          quotaInitialized.value = true;
        }
        final savedQuota = (b.spendingQuota ?? '0').trim();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            spacing: 16,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BillingStandingCard(
                blacklisted: b.blacklisted,
                onSettle: () => _settle(context, ref),
              ),
              _SpendingQuotaCard(
                controller: quotaController,
                canSave: quotaText.isNotEmpty && quotaText != savedQuota,
                onSave: () => _saveQuota(context, ref, quotaText),
              ),
              _MeteredUsageCard(usage: b.usage),
            ],
          ),
        );
      },
      error: (e, _) => _ResponseError(
        error: e,
        onRetry: () => ref.invalidate(personalityBillingProvider),
      ),
      loading: () => const _ResponseLoading(),
    );
  }

  Future<void> _saveQuota(
    BuildContext context,
    WidgetRef ref,
    String value,
  ) async {
    _showLoadingModal(context);
    try {
      final dio = ref.read(personalityApiClientProvider);
      await dio.put(
        '/personality/billing/me/spending-quota',
        data: {'spending_quota': value},
      );
      ref.invalidate(personalityBillingProvider);
      if (context.mounted) showSnackBar('Settings saved');
    } catch (e) {
      if (context.mounted) _showErrorAlert(context, e);
    } finally {
      if (context.mounted) _hideLoadingModal(context);
    }
  }

  Future<void> _settle(BuildContext context, WidgetRef ref) async {
    _showLoadingModal(context);
    try {
      final dio = ref.read(personalityApiClientProvider);
      await dio.post('/personality/billing/me/settle');
      ref.invalidate(personalityBillingProvider);
      if (context.mounted) showSnackBar('Usage settled');
    } catch (e) {
      if (context.mounted) _showErrorAlert(context, e);
    } finally {
      if (context.mounted) _hideLoadingModal(context);
    }
  }
}

/// Whether the account can run at all, and the way back when it cannot: one
/// card, because a suspended account's first question is what to do about it.
class _BillingStandingCard extends StatelessWidget {
  const _BillingStandingCard({
    required this.blacklisted,
    required this.onSettle,
  });

  final bool blacklisted;
  final VoidCallback onSettle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = blacklisted ? scheme.error : scheme.primary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Row(
              children: [
                Icon(
                  blacklisted ? Symbols.block : Symbols.check_circle,
                  color: accent,
                ),
                const Gap(10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        blacklisted ? 'Billing suspended' : 'Active',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: blacklisted ? scheme.error : null,
                        ),
                      ),
                      Text(
                        blacklisted
                            ? 'New runs are stopped until the account settles.'
                            : 'Runs are metered and billed as usual.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (blacklisted)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: onSettle,
                  icon: const Icon(Symbols.paid),
                  label: const Text('Settle unpaid usage'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The unpaid amount that trips an immediate wallet charge. The server reads
/// it in the account's billing currency and settles only the default one, so
/// the field carries no currency suffix; `0` leaves settlement to the daily
/// run.
class _SpendingQuotaCard extends StatelessWidget {
  const _SpendingQuotaCard({
    required this.controller,
    required this.canSave,
    required this.onSave,
  });

  final TextEditingController controller;
  final bool canSave;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text('Spending quota', style: theme.textTheme.titleSmall),
            Text(
              'Charge the wallet once unpaid usage reaches this amount. '
              '0 settles only in the daily run.',
              style: theme.textTheme.bodySmall,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (canSave) onSave();
                    },
                    decoration: const InputDecoration(hintText: '0'),
                  ),
                ),
                const Gap(8),
                FilledButton(
                  onPressed: canSave ? onSave : null,
                  child: const Text('Save quota'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the account spent this hour and today, per currency, against the
/// configured interval limit when there is one.
class _MeteredUsageCard extends StatelessWidget {
  const _MeteredUsageCard({required this.usage});

  final SnPersonalityBillingUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = usage.hourlyUsage.isEmpty && usage.dailyUsage.isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text('Metered usage', style: theme.textTheme.titleSmall),
            if (empty)
              Text(
                'Nothing metered this hour or today.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              _UsageInterval(label: 'This hour', usage: usage.hourlyUsage),
              _UsageInterval(label: 'Today', usage: usage.dailyUsage),
            ],
          ],
        ),
      ),
    );
  }
}

/// One interval's rows: a currency, what it has consumed, and a bar for how
/// far along a limit it is. An interval with no metered currency says so
/// rather than vanishing, so the hour and the day stay comparable.
class _UsageInterval extends StatelessWidget {
  const _UsageInterval({required this.label, required this.usage});

  final String label;
  final Map<String, SnPersonalityRunUsage> usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = usage.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (rows.isEmpty)
          Text('Nothing metered.', style: theme.textTheme.bodySmall)
        else
          for (final row in rows)
            _UsageRow(label: _localizeCurrency(row.key), usage: row.value),
      ],
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.label, required this.usage});

  final String label;
  final SnPersonalityRunUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = usage.max == null ? null : double.tryParse(usage.max!.trim());
    final used = double.tryParse(usage.used.trim()) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Text(
              max == null
                  ? '${_formatAmount(usage.used)} used'
                  : '${_formatAmount(usage.used)} / ${_formatAmount(usage.max!)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (max != null && max > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: (used / max).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHigh,
            ),
          ),
      ],
    );
  }
}

/// The account's spending, as a receipt: what the companion consumed, which
/// call consumed it, and where that call came from.
///
/// The breakdown rows are the filter. Tapping a device, an endpoint or an
/// action narrows the charge list to it, so finding "what spent my golds" never
/// means filling in a form — and because the breakdown is not narrowed with the
/// list, the overview stays whole while the reader drills down.
class AiConsoleUsageTab extends HookConsumerWidget {
  const AiConsoleUsageTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = useState<int>(7);
    final filterKey = useState<String?>(null);
    final filterValue = useState<String?>(null);
    final windowQuery = SnLedgerQuery(days: days.value);
    final listQuery = SnLedgerQuery(
      days: days.value,
      key: filterKey.value,
      value: filterValue.value,
    );
    final summary = ref.watch(personalityLedgerSummaryProvider(windowQuery));
    final ledger = ref.watch(personalityBillingLedgerProvider(listQuery));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        spacing: 16,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('Search provider'),
          const _SearchProviderCard(),
          const _SectionTitle('Spend'),
          _SpendControls(
            query: listQuery,
            onWindow: (value) => days.value = value,
            onClear: () {
              filterKey.value = null;
              filterValue.value = null;
            },
          ),
          summary.when(
            data: (value) => _SpendBreakdown(
              summary: value,
              onFilter: (key, value) {
                filterKey.value = key;
                filterValue.value = value;
              },
            ),
            error: (e, _) => _ResponseError(
              error: e,
              onRetry: () =>
                  ref.invalidate(personalityLedgerSummaryProvider(windowQuery)),
            ),
            loading: () => const _ResponseLoading(),
          ),
          const _SectionTitle('Recent charges'),
          ledger.when(
            data: (entries) => _LedgerCard(entries: entries),
            error: (e, _) => _ResponseError(
              error: e,
              onRetry: () =>
                  ref.invalidate(personalityBillingLedgerProvider(listQuery)),
            ),
            loading: () => const _ResponseLoading(),
          ),
        ],
      ),
    );
  }
}

/// Where the companion's searches run, and what each choice costs.
///
/// The choice only means anything while the server runs the search: with the
/// on-device search plugin on, the call leaves from this machine and the server
/// never sees it, so the card says so rather than showing a setting that does
/// nothing.
class _SearchProviderCard extends ConsumerWidget {
  const _SearchProviderCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final choice = ref.watch(personalitySearchChoiceProvider);
    final onDevice = ref
        .watch(pluginEnablementProvider)
        .contains(const WebSearchPlugin().id);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 8,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where searches run', style: theme.textTheme.titleSmall),
            Text(
              onDevice
                  ? 'Searches run on this device right now. This choice applies once Web search is off in General.'
                  : 'Only the chosen engine is queried, so the price of a search is the one you picked.',
              style: theme.textTheme.labelSmall,
            ),
            const Gap(4),
            choice.when(
              data: (value) => Column(
                children: [
                  _EngineRow(
                    label: 'Server default',
                    detail: 'whichever engine answers first',
                    selected: value.preference.engine.isEmpty,
                    onTap: () => _chooseEngine(context, ref, ''),
                  ),
                  for (final engine in value.catalog.engines)
                    _EngineRow(
                      label: engine.id,
                      detail: _engineCost(engine, value.catalog.currency),
                      selected: value.preference.engine == engine.id,
                      onTap: () => _chooseEngine(context, ref, engine.id),
                    ),
                ],
              ),
              error: (e, _) => _ResponseError(
                error: e,
                onRetry: () =>
                    ref.invalidate(personalitySearchChoiceProvider),
              ),
              loading: () => const _ResponseLoading(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseEngine(
    BuildContext context,
    WidgetRef ref,
    String engine,
  ) async {
    _showLoadingModal(context);
    try {
      final dio = ref.read(personalityApiClientProvider);
      await dio.put(
        '/personality/web/search/preference',
        data: {'engine': engine},
      );
      ref.invalidate(personalitySearchChoiceProvider);
      if (context.mounted) {
        showSnackBar(
          engine.isEmpty
              ? 'Searches will use any engine'
              : 'Searches will use $engine',
        );
      }
    } catch (e) {
      if (context.mounted) _showErrorAlert(context, e);
    } finally {
      if (context.mounted) _hideLoadingModal(context);
    }
  }
}

/// One engine, as a row of the choice. The radio is the whole row's target.
class _EngineRow extends StatelessWidget {
  const _EngineRow({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(
              selected
                  ? Symbols.radio_button_checked
                  : Symbols.radio_button_unchecked,
              size: 18,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const Gap(10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: PersynthFonts.mono,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(detail, style: theme.textTheme.labelSmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The window and the active narrowing, as the chips above the spend card.
class _SpendControls extends StatelessWidget {
  const _SpendControls({
    required this.query,
    required this.onWindow,
    required this.onClear,
  });

  final SnLedgerQuery query;
  final ValueChanged<int> onWindow;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in _ledgerWindows.entries)
          _Pill(
            label: entry.value,
            selected: query.days == entry.key,
            onTap: () => onWindow(entry.key),
          ),
        if (query.key != null && query.value != null)
          _Pill(
            label:
                '${_ledgerDimensionLabel(query.key!)}: ${query.value}',
            selected: true,
            icon: Symbols.close,
            onTap: onClear,
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (icon != null) ...[
                const Gap(6),
                Icon(icon, size: 14, color: foreground),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The window's total, then what made it up — by action, endpoint, device,
/// address and credential. Each row is the way into the charges behind it.
class _SpendBreakdown extends StatelessWidget {
  const _SpendBreakdown({required this.summary, required this.onFilter});

  final SnLedgerSummary summary;
  final void Function(String key, String value) onFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = summary.byCurrency.isEmpty
        ? '0'
        : summary.byCurrency
              .map(
                (bucket) =>
                    '${_formatAmount(bucket.amount)} ${_localizeCurrency(bucket.currency)}',
              )
              .join(' · ');
    final credentials = summary.byCredential
        .where((bucket) => bucket.key.isNotEmpty)
        .toList();
    final groups = <(String, String, List<SnLedgerBucket>)>[
      ('By action', 'action', summary.byAction),
      ('By endpoint', 'surface', summary.bySurface),
      ('By device', 'device', summary.byDeviceId),
      ('By address', 'ip', summary.byClientIp),
      ('By credential', 'credential', credentials),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          spacing: 12,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    total,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFamily: PersynthFonts.mono,
                    ),
                  ),
                ),
                Text(
                  '${summary.entries} ${summary.entries == 1 ? 'charge' : 'charges'}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            if (summary.entries == 0)
              Text(
                'Nothing was metered in this window.',
                style: theme.textTheme.bodySmall,
              )
            else
              for (final (title, dimension, buckets) in groups)
                if (buckets.isNotEmpty)
                  _BucketGroup(
                    title: title,
                    dimension: dimension,
                    buckets: buckets,
                    onFilter: onFilter,
                  ),
          ],
        ),
      ),
    );
  }
}

class _BucketGroup extends StatelessWidget {
  const _BucketGroup({
    required this.title,
    required this.dimension,
    required this.buckets,
    required this.onFilter,
  });

  final String title;
  final String dimension;
  final List<SnLedgerBucket> buckets;
  final void Function(String key, String value) onFilter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A reader knows "Reply" and "Search · tavily"; a device, an endpoint and an
    // address are identifiers, and identifiers stay in mono.
    final identifier = dimension != 'action';
    final shown = buckets.take(_kBreakdownRows).toList();
    final hidden = buckets.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        for (final bucket in shown)
          InkWell(
            onTap: () => onFilter(dimension, bucket.key),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      identifier
                          ? (bucket.key.isEmpty ? 'none' : bucket.key)
                          : _actionLabel(bucket.key),
                      style: identifier
                          ? theme.textTheme.bodySmall?.copyWith(
                              fontFamily: PersynthFonts.mono,
                            )
                          : theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${_formatAmount(bucket.amount)} ${_localizeCurrency(bucket.currency)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text('+$hidden more', style: theme.textTheme.labelSmall),
          ),
      ],
    );
  }
}

class _LedgerCard extends StatelessWidget {
  const _LedgerCard({required this.entries});

  final List<SnLedgerEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: entries.isEmpty
          ? const _EmptyNote(message: 'No charges in this window.')
          : Column(
              children: [
                for (final (index, entry) in entries.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  _LedgerRow(entry: entry),
                ],
              ],
            ),
    );
  }
}

/// One charge. The amount is right-aligned and set in mono so a column of them
/// scans like a receipt; under it sits the priced model and the call the charge
/// came from.
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final SnLedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = entry.model == entry.action ? '' : entry.model;
    final where = [
      if (entry.surface.isNotEmpty) entry.surface,
      if (entry.deviceId.isNotEmpty) entry.deviceId,
      if (entry.clientIp.isNotEmpty) entry.clientIp,
      if (entry.createdAt != null) _formatCreatedAt(entry.createdAt!),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 3,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  _actionLabel(entry.action),
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Gap(12),
              Text(
                '${_formatAmount(entry.originalAmount)} ${_localizeCurrency(entry.currency)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (model.isNotEmpty)
            Text(
              model,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: PersynthFonts.mono,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          if (where.isNotEmpty)
            Text(
              where.join(' · '),
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

class AiConsoleCredentialsTab extends ConsumerWidget {
  const AiConsoleCredentialsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creds = ref.watch(personalityCredentialsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: FilledButton.icon(
            onPressed: () => _showCreateSheet(context, ref),
            icon: const Icon(Symbols.add),
            label: Text('Create credential'),
          ),
        ),
        Expanded(
          child: creds.when(
            data: (list) => list.isEmpty
                ? const Center(child: _EmptyNote())
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _CredentialCard(credential: list[i]),
                    ),
                  ),
            error: (e, _) => _ResponseError(
              error: e,
              onRetry: () => ref.invalidate(personalityCredentialsProvider),
            ),
            loading: () => const _ResponseLoading(),
          ),
        ),
      ],
    );
  }

  void _showCreateSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _CreateCredentialSheet(),
    );
  }
}

class _CredentialCard extends ConsumerWidget {
  final SnPersonalityCredential credential;
  const _CredentialCard({required this.credential});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final created = _formatCreatedAt(credential.createdAt);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Symbols.key,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const Gap(12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(credential.name, style: theme.textTheme.titleMedium),
                  Text(
                    '${'Token'}: ${credential.tokenPrefix}',
                    style: theme.textTheme.labelSmall,
                  ),
                  Text(
                    '${'Usage'}: ${credential.usageUsed} / ${credential.usageLimit} ${_localizeCurrency(credential.usageCurrency)}',
                    style: theme.textTheme.labelSmall,
                  ),
                  Text(
                    '${'Created'}: $created',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Symbols.delete_forever, color: Colors.red),
              onPressed: () => _revoke(context, ref, credential),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    SnPersonalityCredential c,
  ) async {
    final confirm = await _showConfirmAlert(
      context,
      'Revoke this credential? This cannot be undone.',
      'Revoke',
      isDanger: true,
    );
    if (!confirm || !context.mounted) return;
    _showLoadingModal(context);
    try {
      final dio = ref.read(personalityApiClientProvider);
      await dio.delete(
        '/personality/openai/credentials/${Uri.encodeComponent(c.id)}',
      );
      ref.invalidate(personalityCredentialsProvider);
      if (context.mounted) showSnackBar('Settings saved');
    } catch (e) {
      if (context.mounted) _showErrorAlert(context, e);
    } finally {
      if (context.mounted) _hideLoadingModal(context);
    }
  }
}

class _CreateCredentialSheet extends HookConsumerWidget {
  const _CreateCredentialSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = useTextEditingController();
    final limit = useTextEditingController(text: '0');
    final currency = useTextEditingController(text: 'USD');
    final submitting = useState(false);
    final createdToken = useState<String?>(null);

    return SheetScaffold(
      titleText: 'Create credential',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: createdToken.value != null
            ? _TokenReveal(
                token: createdToken.value!,
                onDone: () => Navigator.of(context).pop(),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  TextField(
                    controller: name,
                    decoration: InputDecoration(labelText: 'Name'),
                  ),
                  TextField(
                    controller: limit,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: 'Usage limit'),
                  ),
                  TextField(
                    controller: currency,
                    decoration: InputDecoration(labelText: 'Currency'),
                  ),
                  const Gap(8),
                  FilledButton(
                    onPressed: submitting.value
                        ? null
                        : () async {
                            if (name.text.trim().isEmpty) {
                              _showErrorAlert(context, 'Name');
                              return;
                            }
                            submitting.value = true;
                            _showLoadingModal(context);
                            try {
                              final dio = ref.read(
                                personalityApiClientProvider,
                              );
                              final resp = await dio.post(
                                '/personality/openai/credentials',
                                data: {
                                  'name': name.text.trim(),
                                  'usage_limit': limit.text.trim(),
                                  'usage_currency': currency.text
                                      .trim()
                                      .toUpperCase(),
                                },
                              );
                              final created =
                                  SnPersonalityCredentialCreated.fromJson(
                                    resp.data as Map<String, dynamic>,
                                  );
                              if (context.mounted) {
                                _hideLoadingModal(context);
                                ref.invalidate(personalityCredentialsProvider);
                                createdToken.value = created.token;
                              }
                            } catch (e) {
                              if (context.mounted) _hideLoadingModal(context);
                              if (context.mounted) _showErrorAlert(context, e);
                            } finally {
                              if (context.mounted) {
                                _hideLoadingModal(context);
                              }
                              submitting.value = false;
                            }
                          },
                    child: Text('Create credential'),
                  ),
                ],
              ),
      ),
    );
  }
}

class _TokenReveal extends StatelessWidget {
  final String token;
  final VoidCallback onDone;
  const _TokenReveal({required this.token, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 12,
      children: [
        Icon(Symbols.key, size: 40, color: theme.colorScheme.primary),
        Text('Credential created', style: theme.textTheme.titleMedium),
        Text(
          'Copy this token now. It will not be shown again.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const Gap(4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(token, style: theme.textTheme.bodyMedium),
        ),
        const Gap(4),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: token)),
                icon: const Icon(Symbols.content_copy),
                label: Text('Copy token'),
              ),
            ),
            const Gap(8),
            Expanded(
              child: FilledButton(onPressed: onDone, child: Text('Done')),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Local replacements for the Island shared widgets (alert/response).
// ---------------------------------------------------------------------------

/// A centered spinner, matching the old shared loading widget.
class _ResponseLoading extends StatelessWidget {
  const _ResponseLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

/// Centered error text with a retry action.
class _ResponseError extends StatelessWidget {
  const _ResponseError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A long server message must scroll rather than overflow the column.
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Symbols.error_outline,
                size: 44,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const Gap(8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  personalityErrorMessage(error),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              const Gap(8),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Surfaces a failed request as a transient snackbar.
void _showErrorAlert(BuildContext context, Object error) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(personalityErrorMessage(error))));
}

/// A simple confirm dialog returning true when the user approves.
Future<bool> _showConfirmAlert(
  BuildContext context,
  String message,
  String title, {
  bool isDanger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            title,
            style: TextStyle(
              color: isDanger ? Theme.of(context).colorScheme.error : null,
            ),
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// A blocking progress modal, shown while a request is in flight.
OverlayEntry? _loadingOverlay;

void _showLoadingModal(BuildContext context) {
  _loadingOverlay?.remove();
  final entry = OverlayEntry(
    builder: (overlayContext) => ColoredBox(
      color: Colors.black38,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const CircularProgressIndicator(),
        ),
      ),
    ),
  );
  Overlay.of(context).insert(entry);
  _loadingOverlay = entry;
}

void _hideLoadingModal(BuildContext context) {
  _loadingOverlay?.remove();
  _loadingOverlay = null;
}

/// A compact absolute timestamp for credentials ("2026-01-02 14:05").
String _formatCreatedAt(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
