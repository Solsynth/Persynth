import 'package:flutter/material.dart';

import 'package:synth_pet/theme/app_theme.dart';

/// The pet's face: an ASCII glyph set in the display face. Mochi is made of
/// text, so the face is typography, drawn in ink on the island.
class PetAvatar extends StatelessWidget {
  const PetAvatar({super.key, this.size = 180, this.face = '>.<'});

  final double size;
  final String face;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: Text(
          face,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: SynthPetFonts.display,
            fontSize: size * .25,
            fontWeight: FontWeight.w600,
            height: 1,
            letterSpacing: -size * .02,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
