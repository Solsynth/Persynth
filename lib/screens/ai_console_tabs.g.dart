// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_console_tabs.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(personalityModels)
final personalityModelsProvider = PersonalityModelsProvider._();

final class PersonalityModelsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SnPersonalityModel>>,
          List<SnPersonalityModel>,
          FutureOr<List<SnPersonalityModel>>
        >
    with
        $FutureModifier<List<SnPersonalityModel>>,
        $FutureProvider<List<SnPersonalityModel>> {
  PersonalityModelsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalityModelsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalityModelsHash();

  @$internal
  @override
  $FutureProviderElement<List<SnPersonalityModel>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SnPersonalityModel>> create(Ref ref) {
    return personalityModels(ref);
  }
}

String _$personalityModelsHash() => r'50abe26ab6fcc0c342d2df63a9732b8fbf05d1d9';

@ProviderFor(personalityBilling)
final personalityBillingProvider = PersonalityBillingProvider._();

final class PersonalityBillingProvider
    extends
        $FunctionalProvider<
          AsyncValue<SnPersonalityBilling>,
          SnPersonalityBilling,
          FutureOr<SnPersonalityBilling>
        >
    with
        $FutureModifier<SnPersonalityBilling>,
        $FutureProvider<SnPersonalityBilling> {
  PersonalityBillingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalityBillingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalityBillingHash();

  @$internal
  @override
  $FutureProviderElement<SnPersonalityBilling> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<SnPersonalityBilling> create(Ref ref) {
    return personalityBilling(ref);
  }
}

String _$personalityBillingHash() =>
    r'555fae25979831148be641ea5fcb86886e243c5a';

@ProviderFor(personalityCredentials)
final personalityCredentialsProvider = PersonalityCredentialsProvider._();

final class PersonalityCredentialsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SnPersonalityCredential>>,
          List<SnPersonalityCredential>,
          FutureOr<List<SnPersonalityCredential>>
        >
    with
        $FutureModifier<List<SnPersonalityCredential>>,
        $FutureProvider<List<SnPersonalityCredential>> {
  PersonalityCredentialsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalityCredentialsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalityCredentialsHash();

  @$internal
  @override
  $FutureProviderElement<List<SnPersonalityCredential>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SnPersonalityCredential>> create(Ref ref) {
    return personalityCredentials(ref);
  }
}

String _$personalityCredentialsHash() =>
    r'9720295c7f4e6e862f8d61b5c77b3f5a640c0139';

/// The account's charges in the window, newest first, narrowed by the reader's
/// chosen breakdown key.

@ProviderFor(personalityBillingLedger)
final personalityBillingLedgerProvider = PersonalityBillingLedgerFamily._();

/// The account's charges in the window, newest first, narrowed by the reader's
/// chosen breakdown key.

final class PersonalityBillingLedgerProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SnLedgerEntry>>,
          List<SnLedgerEntry>,
          FutureOr<List<SnLedgerEntry>>
        >
    with
        $FutureModifier<List<SnLedgerEntry>>,
        $FutureProvider<List<SnLedgerEntry>> {
  /// The account's charges in the window, newest first, narrowed by the reader's
  /// chosen breakdown key.
  PersonalityBillingLedgerProvider._({
    required PersonalityBillingLedgerFamily super.from,
    required SnLedgerQuery super.argument,
  }) : super(
         retry: null,
         name: r'personalityBillingLedgerProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$personalityBillingLedgerHash();

  @override
  String toString() {
    return r'personalityBillingLedgerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<List<SnLedgerEntry>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SnLedgerEntry>> create(Ref ref) {
    final argument = this.argument as SnLedgerQuery;
    return personalityBillingLedger(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is PersonalityBillingLedgerProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$personalityBillingLedgerHash() =>
    r'bcc9d922bc4a2d7117d24c603c5889473efb2713';

/// The account's charges in the window, newest first, narrowed by the reader's
/// chosen breakdown key.

final class PersonalityBillingLedgerFamily extends $Family
    with
        $FunctionalFamilyOverride<
          FutureOr<List<SnLedgerEntry>>,
          SnLedgerQuery
        > {
  PersonalityBillingLedgerFamily._()
    : super(
        retry: null,
        name: r'personalityBillingLedgerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The account's charges in the window, newest first, narrowed by the reader's
  /// chosen breakdown key.

  PersonalityBillingLedgerProvider call(SnLedgerQuery query) =>
      PersonalityBillingLedgerProvider._(argument: query, from: this);

  @override
  String toString() => r'personalityBillingLedgerProvider';
}

/// The window's spend along every audit dimension. The reader's filter is
/// deliberately not part of this: the breakdown is the overview the filter is
/// chosen from, so narrowing the list must not narrow the breakdown with it.

@ProviderFor(personalityLedgerSummary)
final personalityLedgerSummaryProvider = PersonalityLedgerSummaryFamily._();

/// The window's spend along every audit dimension. The reader's filter is
/// deliberately not part of this: the breakdown is the overview the filter is
/// chosen from, so narrowing the list must not narrow the breakdown with it.

final class PersonalityLedgerSummaryProvider
    extends
        $FunctionalProvider<
          AsyncValue<SnLedgerSummary>,
          SnLedgerSummary,
          FutureOr<SnLedgerSummary>
        >
    with $FutureModifier<SnLedgerSummary>, $FutureProvider<SnLedgerSummary> {
  /// The window's spend along every audit dimension. The reader's filter is
  /// deliberately not part of this: the breakdown is the overview the filter is
  /// chosen from, so narrowing the list must not narrow the breakdown with it.
  PersonalityLedgerSummaryProvider._({
    required PersonalityLedgerSummaryFamily super.from,
    required SnLedgerQuery super.argument,
  }) : super(
         retry: null,
         name: r'personalityLedgerSummaryProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$personalityLedgerSummaryHash();

  @override
  String toString() {
    return r'personalityLedgerSummaryProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  $FutureProviderElement<SnLedgerSummary> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<SnLedgerSummary> create(Ref ref) {
    final argument = this.argument as SnLedgerQuery;
    return personalityLedgerSummary(ref, argument);
  }

  @override
  bool operator ==(Object other) {
    return other is PersonalityLedgerSummaryProvider &&
        other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$personalityLedgerSummaryHash() =>
    r'7c157ae1c8e11ad92c5d768f5973ed5b7f7a6bb6';

/// The window's spend along every audit dimension. The reader's filter is
/// deliberately not part of this: the breakdown is the overview the filter is
/// chosen from, so narrowing the list must not narrow the breakdown with it.

final class PersonalityLedgerSummaryFamily extends $Family
    with $FunctionalFamilyOverride<FutureOr<SnLedgerSummary>, SnLedgerQuery> {
  PersonalityLedgerSummaryFamily._()
    : super(
        retry: null,
        name: r'personalityLedgerSummaryProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  /// The window's spend along every audit dimension. The reader's filter is
  /// deliberately not part of this: the breakdown is the overview the filter is
  /// chosen from, so narrowing the list must not narrow the breakdown with it.

  PersonalityLedgerSummaryProvider call(SnLedgerQuery query) =>
      PersonalityLedgerSummaryProvider._(argument: query, from: this);

  @override
  String toString() => r'personalityLedgerSummaryProvider';
}

/// The engines a search can be kept on, and the one this account is on, read
/// together because the picker needs both to draw a single choice.

@ProviderFor(personalitySearchChoice)
final personalitySearchChoiceProvider = PersonalitySearchChoiceProvider._();

/// The engines a search can be kept on, and the one this account is on, read
/// together because the picker needs both to draw a single choice.

final class PersonalitySearchChoiceProvider
    extends
        $FunctionalProvider<
          AsyncValue<SnWebSearchChoice>,
          SnWebSearchChoice,
          FutureOr<SnWebSearchChoice>
        >
    with
        $FutureModifier<SnWebSearchChoice>,
        $FutureProvider<SnWebSearchChoice> {
  /// The engines a search can be kept on, and the one this account is on, read
  /// together because the picker needs both to draw a single choice.
  PersonalitySearchChoiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalitySearchChoiceProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalitySearchChoiceHash();

  @$internal
  @override
  $FutureProviderElement<SnWebSearchChoice> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<SnWebSearchChoice> create(Ref ref) {
    return personalitySearchChoice(ref);
  }
}

String _$personalitySearchChoiceHash() =>
    r'ba0fc1080a64504745bd6eb631fc20e7aeb5c421';
