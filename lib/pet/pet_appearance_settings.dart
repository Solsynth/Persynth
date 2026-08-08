import 'package:shared_preferences/shared_preferences.dart';

class PetAppearance {
  const PetAppearance({
    required this.leftEye,
    required this.mouth,
    required this.rightEye,
  });

  static const defaultValue = PetAppearance(
    leftEye: '0',
    mouth: '.',
    rightEye: '0',
  );

  final String leftEye;
  final String mouth;
  final String rightEye;

  String get face => '$leftEye$mouth$rightEye';

  PetAppearance copyWith({String? leftEye, String? mouth, String? rightEye}) {
    return PetAppearance(
      leftEye: leftEye ?? this.leftEye,
      mouth: mouth ?? this.mouth,
      rightEye: rightEye ?? this.rightEye,
    );
  }
}

class PetAppearanceSettings {
  const PetAppearanceSettings({this._preferences});

  static const _leftEyeKey = 'pet_left_eye';
  static const _mouthKey = 'pet_mouth';
  static const _rightEyeKey = 'pet_right_eye';

  final SharedPreferencesAsync? _preferences;

  Future<PetAppearance> load() async {
    final preferences = _preferences ?? SharedPreferencesAsync();
    return PetAppearance(
      leftEye:
          await preferences.getString(_leftEyeKey) ??
          PetAppearance.defaultValue.leftEye,
      mouth:
          await preferences.getString(_mouthKey) ??
          PetAppearance.defaultValue.mouth,
      rightEye:
          await preferences.getString(_rightEyeKey) ??
          PetAppearance.defaultValue.rightEye,
    );
  }

  Future<void> save(PetAppearance appearance) async {
    final preferences = _preferences ?? SharedPreferencesAsync();
    await Future.wait([
      preferences.setString(_leftEyeKey, appearance.leftEye),
      preferences.setString(_mouthKey, appearance.mouth),
      preferences.setString(_rightEyeKey, appearance.rightEye),
    ]);
  }
}
