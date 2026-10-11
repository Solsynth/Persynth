/// Binds the shared step-up elevation ("sudo") flow to the app's own client
/// and error surface.
///
/// `solar_network_foundation` owns the flow — the sheet, the factor widgets and
/// `withSudoRetry` — but never reaches into app state: the host hands it the
/// authenticated client and the way a failure is shown, exactly the way the
/// drive takes its client through overrides. Solian and SolWatt bind the same
/// two overrides.
///
/// Nothing is wired for a gated call the app does not make: see the report
/// accompanying this change for the endpoints searched and not found here.
library;

import 'package:island_ui_foundation/island_ui_foundation.dart';
import 'package:solar_network_foundation/solar_network_foundation.dart';
import 'package:solar_network_sdk/solar_network_sdk.dart';

import 'package:persynth/personality/personality_api.dart';
import 'package:persynth/personality/personality_network.dart';

/// Reports a failure to the user the way the rest of the app does.
///
/// The shared area calls this when an elevation cannot even be started — the
/// account has no factor that can satisfy it, the server refuses the challenge
/// — so a refused step-up is seen rather than swallowed.
///
/// `showSnackBar` is the app's own transient surface (the settings saves, the
/// conversation actions) and `personalityErrorMessage` is how every failed
/// request is worded, so a refusal reads the same here as anywhere else.
void showAppError(Object error) => showSnackBar(personalityErrorMessage(error));

/// The overrides the app's `ProviderScope` installs for the shared auth area.
///
/// The return type is inferred because Riverpod keeps `Override` out of its
/// public API surface, so it cannot be named here.
// ignore: strict_top_level_inference
authHostOverrides() => [
  // The flow's own Stargate calls — opening the challenge, listing its
  // factors, submitting a step — ride the app's one authenticated client, so
  // they carry the same token and the same single-flight 401 refresh as every
  // other request. A client of its own would be a second session, and the
  // elevation would be granted to a session the app does not use.
  authClientProvider.overrideWith(
    (ref) =>
        SolarNetworkClient.fromDio(ref.watch(personalityApiClientProvider)),
  ),
  authErrorReporterProvider.overrideWithValue(showAppError),
];
