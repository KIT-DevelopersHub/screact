import 'package:flutter/material.dart';

/// Shared visual tokens for the production desktop experience.
///
/// Keeping asset names and colors here prevents the connection, calibration,
/// drawing, and settings screens from drifting apart as they are refined.
abstract final class ProductionDesign {
  static const String backgroundAsset =
      'assets/production_watercolor_background.png';
  static const String characterAsset = 'assets/production_character.png';

  static const Color backgroundFallback = Color(0xFFF3FBF9);
  static const Color headerColor = Color(0xFFC8CCE8);
  static const Color headerForeground = Color(0xFFF9FCF8);
  static const Color textColor = Color(0xFF3F3F3F);
  static const Color darkButton = Color(0xFF666565);
  static const Color buttonDisabled = Color(0xFFA8A6A6);
  static const Color panel = Color(0xF7FFFFFF);
  static const Color panelBorder = Color(0xFF575454);

  static const double headerHeight = 84;
  static const double controlRadius = 20;
  static const double panelRadius = 22;
}

/// Paints the shared watercolor asset behind [child].
///
/// [fit] defaults to [BoxFit.cover] so the background fills differently sized
/// desktop windows without distorting foreground content. If the asset is not
/// available, the screen remains usable with [fallbackColor].
class WatercolorBackground extends StatelessWidget {
  const WatercolorBackground({
    super.key,
    required this.child,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fallbackColor = ProductionDesign.backgroundFallback,
  });

  final Widget child;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final Color fallbackColor;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: fallbackColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeSemantics(
            child: Image.asset(
              ProductionDesign.backgroundAsset,
              fit: fit,
              alignment: alignment,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// The common lavender desktop header.
///
/// The stable keys are intentionally part of this widget's contract so widget
/// tests and accessibility tooling can locate the two global navigation actions.
class ProductionHeader extends StatelessWidget implements PreferredSizeWidget {
  const ProductionHeader({
    super.key,
    required this.onMenu,
    required this.onSettings,
    this.showSettings = true,
    this.height = ProductionDesign.headerHeight,
    this.horizontalPadding = 18,
    this.backgroundColor = ProductionDesign.headerColor,
    this.foregroundColor = ProductionDesign.headerForeground,
  });

  static const Key menuKey = Key('desktop-header-menu');
  static const Key settingsKey = Key('desktop-header-settings');

  final VoidCallback onMenu;
  final VoidCallback onSettings;
  final bool showSettings;
  final double height;
  final double horizontalPadding;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                key: menuKey,
                tooltip: 'メニュー',
                onPressed: onMenu,
                color: foregroundColor,
                iconSize: 40,
                icon: const Icon(Icons.menu_rounded),
              ),
              if (showSettings)
                IconButton(
                  key: settingsKey,
                  tooltip: '設定',
                  onPressed: onSettings,
                  color: foregroundColor,
                  iconSize: 40,
                  icon: const Icon(Icons.settings_outlined),
                )
              else
                const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }
}

/// A production-style dark gray action button.
///
/// The optional [icon] stays grouped with the label and the complete group
/// remains centered. [width] may be omitted when the parent should determine
/// the horizontal size.
class ProductionButton extends StatelessWidget {
  const ProductionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.outlined = false,
    this.width,
    this.height = 58,
    this.horizontalPadding = 32,
    this.backgroundColor = ProductionDesign.darkButton,
    this.foregroundColor = Colors.white,
    this.borderRadius = ProductionDesign.controlRadius,
    this.textStyle,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool outlined;
  final double? width;
  final double height;
  final double horizontalPadding;
  final Color backgroundColor;
  final Color foregroundColor;
  final double borderRadius;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final effectiveTextStyle =
        textStyle ??
        const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.1);

    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 28), const SizedBox(width: 12)],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
    );
    final button =
        outlined
            ? OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: ProductionDesign.textColor,
                disabledForegroundColor: ProductionDesign.buttonDisabled,
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                side: const BorderSide(
                  color: ProductionDesign.panelBorder,
                  width: 2,
                ),
                shape: shape,
                textStyle: effectiveTextStyle,
              ),
              child: child,
            )
            : FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: backgroundColor,
                disabledBackgroundColor: ProductionDesign.buttonDisabled,
                foregroundColor: foregroundColor,
                disabledForegroundColor: Colors.white70,
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                shape: shape,
                textStyle: effectiveTextStyle,
              ),
              child: child,
            );

    return SizedBox(width: width, height: height, child: button);
  }
}

/// Displays the existing transparent-background YubiBoard character asset.
class CharacterMascot extends StatelessWidget {
  const CharacterMascot({
    super.key,
    this.size,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.semanticLabel,
  });

  final double? size;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final height = size == null ? null : size! * 0.75;
    return SizedBox(
      width: size,
      height: height,
      child: Image.asset(
        ProductionDesign.characterAsset,
        fit: fit,
        alignment: alignment,
        semanticLabel: semanticLabel,
        excludeFromSemantics: semanticLabel == null,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}

/// A responsive white content panel with the production border treatment.
///
/// The panel expands to the width offered by its parent, but never exceeds
/// [maxWidth]. This makes it suitable inside a centered `Padding` without
/// embedding any screen-specific breakpoint or fixed window assumption.
class ProductionPanel extends StatelessWidget {
  const ProductionPanel({
    super.key,
    required this.child,
    this.maxWidth = 1120,
    EdgeInsetsGeometry? padding,
    this.margin = EdgeInsets.zero,
    this.alignment = Alignment.center,
    this.backgroundColor = ProductionDesign.panel,
    this.borderColor = ProductionDesign.panelBorder,
    this.borderWidth = 2,
    this.borderRadius = ProductionDesign.panelRadius,
  }) : padding = padding ?? const EdgeInsets.all(24);

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final AlignmentGeometry alignment;
  final Color backgroundColor;
  final Color borderColor;
  final double borderWidth;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor,
          border: Border.all(color: borderColor, width: borderWidth),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: child,
      ),
    );
  }
}
