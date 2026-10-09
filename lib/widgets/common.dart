import 'package:flutter/material.dart';

import '../theme.dart';

/// Apparition douce (fondu + léger glissement), avec délai optionnel.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final double offsetY;
  const FadeSlideIn(
      {super.key, required this.child, this.delay = Duration.zero, this.offsetY = 18});

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  late final _a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        child: widget.child,
        builder: (_, child) => Opacity(
          opacity: _a.value,
          child: Transform.translate(
              offset: Offset(0, (1 - _a.value) * widget.offsetY), child: child),
        ),
      );
}

/// Carte arrondie standard.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const AppCard(
      {super.key, required this.child, this.padding = const EdgeInsets.all(18), this.onTap});

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      );
}

/// Montant en euros qui défile jusqu'à sa valeur.
class AnimatedEuro extends StatelessWidget {
  final double value;
  final TextStyle? style;
  final bool signed;
  final Duration duration;
  const AnimatedEuro(
      {super.key,
      required this.value,
      this.style,
      this.signed = false,
      this.duration = const Duration(milliseconds: 1100)});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: value),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (_, v, __) => Text(euros(v, signed: signed),
            style: style?.copyWith(fontFeatures: tabular)),
      );
}

enum AlertLevel { critical, warning, info }

/// Bandeau d'alerte coloré.
class AlertBanner extends StatelessWidget {
  final String text;
  final AlertLevel level;
  const AlertBanner({super.key, required this.text, required this.level});

  static AlertLevel levelOf(String w) {
    if (w.startsWith('⛔')) return AlertLevel.critical;
    final l = w.toLowerCase();
    if (l.startsWith('défauts') ||
        l.contains('introuvable') ||
        l.contains('impossible') ||
        l.contains('indisponible') ||
        l.contains('incertaine') ||
        l.contains('inconnu')) {
      return AlertLevel.warning;
    }
    return AlertLevel.info;
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (level) {
      AlertLevel.critical => (AppColors.bad, Icons.block),
      AlertLevel.warning => (AppColors.warn, Icons.warning_amber_rounded),
      AlertLevel.info => (Theme.of(context).colorScheme.primary, Icons.info_outline),
    };
    final clean = text.replaceFirst(RegExp(r'^⛔\s*'), '');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(clean,
              style: TextStyle(
                  fontWeight: level == AlertLevel.critical ? FontWeight.w700 : FontWeight.w500,
                  height: 1.3)),
        ),
      ]),
    );
  }
}

/// Petite pastille (verdict, source…).
class Pill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  const Pill({super.key, required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
          ],
          Text(label,
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ]),
      );
}
