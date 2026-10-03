// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'personality_api.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(personalityAgents)
final personalityAgentsProvider = PersonalityAgentsProvider._();

final class PersonalityAgentsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SnPersonalityAgent>>,
          List<SnPersonalityAgent>,
          FutureOr<List<SnPersonalityAgent>>
        >
    with
        $FutureModifier<List<SnPersonalityAgent>>,
        $FutureProvider<List<SnPersonalityAgent>> {
  PersonalityAgentsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalityAgentsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalityAgentsHash();

  @$internal
  @override
  $FutureProviderElement<List<SnPersonalityAgent>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SnPersonalityAgent>> create(Ref ref) {
    return personalityAgents(ref);
  }
}

String _$personalityAgentsHash() => r'23550f99c85bd2e56563b6fd0ea673d17666461f';

/// The account's threads, newest first.

@ProviderFor(personalityConversations)
final personalityConversationsProvider = PersonalityConversationsProvider._();

/// The account's threads, newest first.

final class PersonalityConversationsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SnPersonalityConversation>>,
          List<SnPersonalityConversation>,
          FutureOr<List<SnPersonalityConversation>>
        >
    with
        $FutureModifier<List<SnPersonalityConversation>>,
        $FutureProvider<List<SnPersonalityConversation>> {
  /// The account's threads, newest first.
  PersonalityConversationsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalityConversationsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalityConversationsHash();

  @$internal
  @override
  $FutureProviderElement<List<SnPersonalityConversation>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SnPersonalityConversation>> create(Ref ref) {
    return personalityConversations(ref);
  }
}

String _$personalityConversationsHash() =>
    r'b222dbab38771085ca58a6470e5c5d64c6a69b95';

/// The account's conversation groups, ordered by name.

@ProviderFor(personalityConversationGroups)
final personalityConversationGroupsProvider =
    PersonalityConversationGroupsProvider._();

/// The account's conversation groups, ordered by name.

final class PersonalityConversationGroupsProvider
    extends
        $FunctionalProvider<
          AsyncValue<List<SnConversationGroup>>,
          List<SnConversationGroup>,
          FutureOr<List<SnConversationGroup>>
        >
    with
        $FutureModifier<List<SnConversationGroup>>,
        $FutureProvider<List<SnConversationGroup>> {
  /// The account's conversation groups, ordered by name.
  PersonalityConversationGroupsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'personalityConversationGroupsProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$personalityConversationGroupsHash();

  @$internal
  @override
  $FutureProviderElement<List<SnConversationGroup>> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<List<SnConversationGroup>> create(Ref ref) {
    return personalityConversationGroups(ref);
  }
}

String _$personalityConversationGroupsHash() =>
    r'6ee142ec0e0ffbc5a0227133f399d11139bbbb66';
