import 'package:auto_route/auto_route.dart';

import 'package:persynth/gate/gate_page.dart';
import 'package:persynth/screens/conversation_page.dart';
import 'package:persynth/screens/pet_page.dart';
import 'package:persynth/screens/settings_page.dart';

part 'router.gr.dart';

@AutoRouterConfig()
class AppRouter extends RootStackRouter {
  AppRouter({this.isPet = false});

  final bool isPet;

  @override
  List<AutoRoute> get routes {
    if (isPet) {
      return [AutoRoute(page: PetRoute.page, path: '/', initial: true)];
    }

    return [
      // The gate is the front door: it hands the user to the conversation as
      // soon as the stored session answers, so the chat is only ever reached
      // with an account behind it.
      AutoRoute(page: GateRoute.page, path: '/', initial: true),
      AutoRoute(page: ConversationRoute.page, path: '/conversation'),
      AutoRoute(page: SettingsRoute.page, path: '/settings'),
    ];
  }
}
