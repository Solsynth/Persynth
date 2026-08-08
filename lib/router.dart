import 'package:auto_route/auto_route.dart';

import 'package:synth_pet/screens/home_page.dart';
import 'package:synth_pet/screens/pet_page.dart';

part 'router.gr.dart';

@AutoRouterConfig(replaceInRouteName: 'Page,Route')
class AppRouter extends RootStackRouter {
  AppRouter({this.isPet = false});

  final bool isPet;

  @override
  List<AutoRoute> get routes {
    if (isPet) {
      return [AutoRoute(page: PetRoute.page, path: '/', initial: true)];
    }

    return [
      AutoRoute(page: HomeRoute.page, path: '/', initial: true),
      AutoRoute(page: PetRoute.page, path: '/pet'),
    ];
  }
}
