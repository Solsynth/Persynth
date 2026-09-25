import 'package:flutter_test/flutter_test.dart';
import 'package:persynth/pet/pet_behavior.dart';

void main() {
  test('parses an AI reply and applies only supported behavior fields', () {
    final response = PetBehaviorResponse.fromAssistantText('''
```json
{"reply":"I am glad you are here.","behavior":{"mood":"happy","face":"^.^","status":"Feeling bright","animation":"bounce","energy":0}}
```
''');
    final controller = PetBehaviorController();

    controller.applyAiDirective(response.directive!);

    expect(response.reply, 'I am glad you are here.');
    expect(controller.state.mood, PetMood.happy);
    expect(controller.state.face, '^.^');
    expect(controller.state.status, 'Feeling bright');
    expect(controller.state.animation, 'bounce');
    expect(controller.state.energy, closeTo(0.72, 0.001));
    expect(controller.state.source, 'ai');
  });

  test(
    'programmatic interactions update resources and override the AI lease',
    () {
      final start = DateTime(2026, 1, 1, 12);
      final controller = PetBehaviorController(now: start);
      controller.applyAiDirective(
        const PetBehaviorDirective(mood: PetMood.sad, face: 'T.T'),
        now: start,
      );

      controller.tick(now: start.add(const Duration(minutes: 1)));
      expect(controller.state.mood, PetMood.sad);

      controller.applyInteraction(PetInteraction.play);
      expect(controller.state.mood, PetMood.excited);
      expect(controller.state.affection, greaterThan(0.58));
      expect(controller.state.source, 'programmatic');
    },
  );

  test('expired AI mood yields to deterministic idle behavior', () {
    final start = DateTime(2026, 1, 1, 12);
    final controller = PetBehaviorController(now: start);
    controller.applyAiDirective(
      const PetBehaviorDirective(mood: PetMood.excited, face: '^.^'),
      now: start,
    );

    controller.tick(now: start.add(const Duration(minutes: 4)));

    expect(controller.state.source, 'programmatic');
    expect(controller.state.mood, isNot(PetMood.excited));
  });

  test('rejects unsafe AI face and animation values', () {
    final controller = PetBehaviorController();
    controller.applyAiDirective(
      const PetBehaviorDirective(
        face: '<script>',
        status: 'Safe status',
        animation: 'execute-code',
      ),
    );

    expect(controller.state.face, PetBehaviorState.initial.face);
    expect(controller.state.status, 'Safe status');
    expect(controller.state.animation, 'none');
  });
}
