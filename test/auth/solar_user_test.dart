import 'package:flutter_test/flutter_test.dart';

import 'package:persynth/auth/solar_auth_service.dart';

/// The account payload `/stargate/accounts/me` answers with, narrowed to what
/// the app reads out of it.
Map<String, dynamic> _account({Map<String, dynamic>? picture}) => {
  'name': 'michan',
  'nick': 'Michan',
  'profile': {'id': 'p0', 'picture': picture},
};

void main() {
  test('the profile picture becomes the account avatar', () {
    final user = SolarUser.fromJson(
      _account(picture: {'id': 'file-1', 'mime_type': 'image/png'}),
    );

    expect(user.pictureId, 'file-1');
    // No storage URL on the reference means the deployment's own drive serves
    // it, which the caller builds from the id.
    expect(user.pictureUrl, isNull);
  });

  test('a picture served from elsewhere keeps its URL', () {
    final user = SolarUser.fromJson(
      _account(picture: {'id': 'file-1', 'url': 'https://cdn.example/f1.png'}),
    );

    expect(user.pictureUrl, 'https://cdn.example/f1.png');
  });

  test('an account without a picture, or without a profile, has no avatar', () {
    expect(SolarUser.fromJson(_account()).pictureId, isNull);
    expect(SolarUser.fromJson(_account(picture: {})).pictureId, isNull);
    expect(SolarUser.fromJson({'name': 'michan'}).pictureId, isNull);
  });
}
