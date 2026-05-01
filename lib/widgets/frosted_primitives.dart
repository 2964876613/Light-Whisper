import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/lightwhisper_theme_v2.dart';

extension LightwhisperThemeContextX on BuildContext {
  LightwhisperThemeV2 get lwTheme =>
      Theme.of(this).extension<LightwhisperThemeV2>() ?? LightwhisperThemeV2.light;
}

class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    return Scaffold(
      appBar: appBar,
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [t.backgroundGradientTop, t.backgroundGradientBottom],
          ),
        ),
        child: body,
      ),
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.useMediumSurface = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool useMediumSurface;

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    final radius = BorderRadius.circular(t.radiusCard);
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: t.shadowMedium,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: padding ?? EdgeInsets.all(t.space16),
            decoration: BoxDecoration(
              color: useMediumSurface ? t.surfaceGlassMedium : t.surfaceGlassSoft,
              borderRadius: radius,
              border: Border.all(color: t.glassBorder),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class PrimaryPillButton extends StatelessWidget {
  const PrimaryPillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.leading,
    this.expanded = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? leading;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    final button = FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: t.primaryAccent,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(horizontal: t.space24, vertical: t.space12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.radiusButton),
        ),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            SizedBox(width: t.space8),
          ],
          Text(label),
        ],
      ),
    );

    if (!expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}

class SoftInput extends StatelessWidget {
  const SoftInput({
    super.key,
    required this.controller,
    this.hintText,
    this.maxLines = 1,
    this.minLines,
    this.onSubmitted,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String? hintText;
  final int maxLines;
  final int? minLines;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    return TextField(
      controller: controller,
      maxLines: maxLines,
      minLines: minLines,
      onSubmitted: onSubmitted,
      textInputAction: textInputAction,
      style: TextStyle(color: t.textPrimary, fontSize: 16),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: t.textSecondary),
        filled: true,
        fillColor: t.surfaceGlassSoft,
        contentPadding: EdgeInsets.symmetric(
          horizontal: t.space16,
          vertical: t.space12,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radiusContainer),
          borderSide: BorderSide(color: t.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(t.radiusContainer),
          borderSide: BorderSide(color: t.primaryAccent, width: 1.3),
        ),
      ),
    );
  }
}
