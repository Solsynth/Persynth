import 'dart:convert';
import 'dart:math' as math;

/// The moods the AI and deterministic pet rules are allowed to use.
enum PetMood { neutral, happy, sad, sleepy, curious, excited, lonely, focused }

extension PetMoodParsing on PetMood {
  String get wireName => name;

  static PetMood? fromWire(String? value) {
    if (value == null) return null;
    for (final mood in PetMood.values) {
      if (mood.name == value.trim().toLowerCase()) return mood;
    }
    return null;
  }
}

enum PetInteraction { feed, play, rest }

/// The complete runtime state shown by the pet window.
class PetBehaviorState {
  const PetBehaviorState({
    required this.mood,
    required this.face,
    required this.status,
    required this.animation,
    required this.energy,
    required this.affection,
    required this.source,
    required this.isThinking,
  });

  static const initial = PetBehaviorState(
    mood: PetMood.neutral,
    face: '0.0',
    status: 'Mochi is here',
    animation: 'none',
    energy: 0.72,
    affection: 0.58,
    source: 'programmatic',
    isThinking: false,
  );

  final PetMood mood;
  final String face;
  final String status;
  final String animation;
  final double energy;
  final double affection;
  final String source;
  final bool isThinking;

  PetBehaviorState copyWith({
    PetMood? mood,
    String? face,
    String? status,
    String? animation,
    double? energy,
    double? affection,
    String? source,
    bool? isThinking,
  }) {
    return PetBehaviorState(
      mood: mood ?? this.mood,
      face: face ?? this.face,
      status: status ?? this.status,
      animation: animation ?? this.animation,
      energy: energy ?? this.energy,
      affection: affection ?? this.affection,
      source: source ?? this.source,
      isThinking: isThinking ?? this.isThinking,
    );
  }
}

/// The only behavior fields the model may directly control.
class PetBehaviorDirective {
  const PetBehaviorDirective({
    this.mood,
    this.face,
    this.status,
    this.animation,
  });

  final PetMood? mood;
  final String? face;
  final String? status;
  final String? animation;

  factory PetBehaviorDirective.fromJson(Map<String, dynamic> json) {
    return PetBehaviorDirective(
      mood: PetMoodParsing.fromWire(json['mood']?.toString()),
      face: json['face']?.toString(),
      status: json['status']?.toString(),
      animation: json['animation']?.toString(),
    );
  }

  bool get isEmpty =>
      mood == null && face == null && status == null && animation == null;
}

class PetBehaviorResponse {
  const PetBehaviorResponse({required this.reply, this.directive});

  final String reply;
  final PetBehaviorDirective? directive;

  /// Accepts the structured response contract, while keeping plain text
  /// responses usable when an older or misconfigured agent answers normally.
  factory PetBehaviorResponse.fromAssistantText(String text) {
    final payload = _decodePayload(text);
    if (payload == null) {
      return PetBehaviorResponse(reply: text.trim());
    }

    final rawBehavior = payload['behavior'];
    final behavior = rawBehavior is Map
        ? PetBehaviorDirective.fromJson(Map<String, dynamic>.from(rawBehavior))
        : null;
    final reply = payload['reply']?.toString().trim();
    return PetBehaviorResponse(
      reply: reply == null || reply.isEmpty ? text.trim() : reply,
      directive: behavior?.isEmpty == false ? behavior : null,
    );
  }

  static Map<String, dynamic>? _decodePayload(String text) {
    final candidates = <String>[
      text.trim(),
      for (final match in RegExp(
        r'```(?:json)?\s*([\s\S]*?)```',
        caseSensitive: false,
      ).allMatches(text))
        match.group(1)!.trim(),
    ];
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      candidates.add(text.substring(start, end + 1));
    }

    for (final candidate in candidates) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // Fall back to the plain assistant response.
      }
    }
    return null;
  }
}

/// Coordinates AI directives with deterministic pet simulation.
///
/// AI owns expression, mood, status, and animation for a short lease. The
/// program owns energy, affection, idle decay, and interaction effects, so a
/// response cannot permanently freeze the pet in one mood.
class PetBehaviorController {
  PetBehaviorController({
    PetBehaviorState initial = PetBehaviorState.initial,
    DateTime? now,
  }) : _state = initial,
       _lastTick = now ?? DateTime.now();

  PetBehaviorState _state;
  DateTime _lastTick;
  DateTime _aiMoodLeaseUntil = DateTime.fromMillisecondsSinceEpoch(0);

  PetBehaviorState get state => _state;

  void setThinking(bool value) {
    _state = _state.copyWith(
      isThinking: value,
      source: value ? 'programmatic' : _state.source,
      face: value ? 'o.o' : _state.face,
      status: value ? 'Thinking...' : _state.status,
      animation: value ? 'pulse' : _state.animation,
    );
  }

  void setAppearance(String face) {
    _state = _state.copyWith(
      face: _safeFace(face) ?? _state.face,
      source: 'programmatic',
    );
  }

  void setStatus(String status, {String? face, String? source}) {
    _state = _state.copyWith(
      status: _safeStatus(status) ?? _state.status,
      face: _safeFace(face) ?? _state.face,
      source: source ?? 'programmatic',
    );
  }

  void applyAiDirective(PetBehaviorDirective directive, {DateTime? now}) {
    if (directive.isEmpty) return;
    final timestamp = now ?? DateTime.now();
    final nextFace = _safeFace(directive.face);
    final nextAnimation = _safeAnimation(directive.animation);
    _state = _state.copyWith(
      mood: directive.mood,
      face: nextFace,
      status: _safeStatus(directive.status),
      animation: nextAnimation,
      source: 'ai',
    );
    if (directive.mood != null) {
      _aiMoodLeaseUntil = timestamp.add(const Duration(minutes: 3));
    }
  }

  void applyInteraction(PetInteraction interaction) {
    _aiMoodLeaseUntil = DateTime.fromMillisecondsSinceEpoch(0);
    switch (interaction) {
      case PetInteraction.feed:
        _state = _state.copyWith(
          mood: PetMood.happy,
          face: '0.0',
          status: 'A tiny snack helps.',
          animation: 'bounce',
          energy: _clamp(_state.energy + 0.18),
          affection: _clamp(_state.affection + 0.05),
          source: 'programmatic',
        );
      case PetInteraction.play:
        _state = _state.copyWith(
          mood: PetMood.excited,
          face: '^.^',
          status: 'That was fun.',
          animation: 'bounce',
          energy: _clamp(_state.energy - 0.12),
          affection: _clamp(_state.affection + 0.16),
          source: 'programmatic',
        );
      case PetInteraction.rest:
        _state = _state.copyWith(
          mood: PetMood.sleepy,
          face: '-.-',
          status: 'A quiet moment.',
          animation: 'none',
          energy: _clamp(_state.energy + 0.12),
          source: 'programmatic',
        );
    }
  }

  void tick({DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final elapsed = timestamp.difference(_lastTick);
    if (elapsed.isNegative || elapsed.inMilliseconds == 0) return;
    _lastTick = timestamp;

    final hours = elapsed.inMilliseconds / Duration.millisecondsPerHour;
    final nextEnergy = _clamp(_state.energy - hours * 0.08);
    final nextAffection = _clamp(_state.affection - hours * 0.025);
    _state = _state.copyWith(energy: nextEnergy, affection: nextAffection);

    if (timestamp.isBefore(_aiMoodLeaseUntil) || _state.isThinking) return;
    final fallbackMood = _programmaticMood(nextEnergy, nextAffection);
    _state = _state.copyWith(
      mood: fallbackMood,
      face: _faceFor(fallbackMood),
      status: _statusFor(fallbackMood),
      animation: fallbackMood == PetMood.excited ? 'pulse' : 'none',
      source: 'programmatic',
    );
  }

  static PetMood _programmaticMood(double energy, double affection) {
    if (energy < 0.22) return PetMood.sleepy;
    if (affection < 0.2) return PetMood.lonely;
    if (energy > 0.84) return PetMood.curious;
    return PetMood.neutral;
  }

  static String _faceFor(PetMood mood) {
    return switch (mood) {
      PetMood.happy || PetMood.excited => '^.^',
      PetMood.sad || PetMood.lonely => 'T.T',
      PetMood.sleepy => '-.-',
      PetMood.curious => 'o.o',
      PetMood.focused => '0.0',
      PetMood.neutral => '0.0',
    };
  }

  static String _statusFor(PetMood mood) {
    return switch (mood) {
      PetMood.sleepy => 'Mochi is getting sleepy.',
      PetMood.lonely => 'Mochi is waiting nearby.',
      PetMood.curious => 'Mochi is wondering about something.',
      _ => 'Mochi is here.',
    };
  }

  static String? _safeFace(String? face) {
    if (face == null) return null;
    final value = face.trim();
    if (value.length != 3 || value.contains('\n')) return null;
    if (!RegExp(r'^[0-9oOT^v<>._-]+$').hasMatch(value)) return null;
    return value;
  }

  static String? _safeStatus(String? status) {
    if (status == null) return null;
    final value = status.trim();
    if (value.isEmpty) return null;
    return value.substring(0, math.min(value.length, 120));
  }

  static String? _safeAnimation(String? animation) {
    if (animation == null) return null;
    const allowed = {'none', 'pulse', 'bounce', 'blink'};
    return allowed.contains(animation.trim().toLowerCase())
        ? animation.trim().toLowerCase()
        : null;
  }

  static double _clamp(double value) => value.clamp(0.0, 1.0).toDouble();
}
