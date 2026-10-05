import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:persynth/auth/solar_auth_service.dart';
import 'package:persynth/theme/app_theme.dart';

/// The code a waiting sign-in needs approved, with the page that takes it.
///
/// The web build signs in with the OAuth device flow: it has no callback to
/// bounce through, so the provider hands out a code and the app polls until the
/// user has entered it in a browser. This is that code. It goes away with the
/// sign-in — approved, declined or expired — because the state holding it does.
class SolarDeviceCodeCard extends StatelessWidget {
  const SolarDeviceCodeCard({super.key, required this.authorization});

  final SolarDeviceAuthorization authorization;

  Future<void> _openVerificationPage() async {
    // platformDefault: the web build is the only one that shows this, and a new
    // tab is what it means there.
    await launchUrl(authorization.verificationUriComplete);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'deviceCodeTitle'.tr(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Gap(6),
          SelectableText(
            authorization.userCode,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontFamily: PersynthFonts.mono,
              fontWeight: FontWeight.w600,
              letterSpacing: 3,
            ),
          ),
          const Gap(6),
          SelectableText(
            authorization.verificationUri.toString(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Gap(10),
          Row(
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const Gap(8),
              Expanded(
                child: Text(
                  'deviceCodeWaiting'.tr(),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: _openVerificationPage,
                icon: const Icon(Symbols.open_in_new_rounded, size: 18),
                label: Text('openPage'.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
