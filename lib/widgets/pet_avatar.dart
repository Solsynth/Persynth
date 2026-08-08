import 'package:flutter/material.dart';

class PetAvatar extends StatelessWidget {
  const PetAvatar({super.key, this.size = 180, this.face = '>.<'});

  final double size;
  final String face;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: Text(
          face,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colors.onPrimaryContainer,
            fontFamily: 'Menlo',
            fontSize: size * .25,
            fontWeight: FontWeight.w700,
            letterSpacing: -size * .025,
          ),
        ),
      ),
    );
  }
}
