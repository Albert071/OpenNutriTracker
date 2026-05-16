import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/theme_mode_provider.dart';
import 'package:opennutritracker/features/settings/presentation/bloc/settings_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Named, hand-picked preset hues that span the wheel and give a coherent
/// Material 3 palette via [ColorScheme.fromSeed]. Sixteen entries arranged
/// 4×4 — enough variety to feel personal, few enough to read at a glance.
const List<double> _presetHues = <double>[
  0,   // red
  18,  // coral
  30,  // orange
  42,  // amber
  60,  // yellow
  84,  // chartreuse
  108, // lime
  140, // green
  165, // teal
  185, // cyan
  205, // sky
  225, // blue
  250, // indigo
  280, // violet
  305, // magenta
  335, // pink
];

class AccentColourScreen extends StatefulWidget {
  const AccentColourScreen({super.key});

  @override
  State<AccentColourScreen> createState() => _AccentColourScreenState();
}

class _AccentColourScreenState extends State<AccentColourScreen> {
  late final SettingsBloc _settingsBloc;

  @override
  void initState() {
    _settingsBloc = locator<SettingsBloc>();
    _settingsBloc.add(LoadSettingsEvent());
    super.initState();
  }

  void _selectMaterialYou() {
    _settingsBloc.setUseMaterialYou(true);
    _settingsBloc.setAccentHue(null);
    final theme = Provider.of<ThemeModeProvider>(context, listen: false);
    theme.updateUseMaterialYou(true);
    theme.updateAccentHue(null);
    _settingsBloc.add(LoadSettingsEvent());
  }

  void _selectHue(double hue) {
    _settingsBloc.setAccentHue(hue);
    // Picking a custom hue should win over Material You — otherwise the
    // chosen colour silently does nothing on Android 12+.
    _settingsBloc.setUseMaterialYou(false);
    final theme = Provider.of<ThemeModeProvider>(context, listen: false);
    theme.updateAccentHue(hue);
    theme.updateUseMaterialYou(false);
    _settingsBloc.add(LoadSettingsEvent());
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).settingsAccentColourTitle)),
      body: BlocBuilder<SettingsBloc, SettingsState>(
        bloc: _settingsBloc,
        builder: (context, state) {
          if (state is! SettingsLoadedState) {
            return const Center(child: CircularProgressIndicator());
          }
          final materialYouActive = isAndroid && state.useMaterialYou;
          final currentHue = state.accentHue;
          return ListView(
            children: [
              if (isAndroid)
                Semantics(
                  identifier: 'accent-option-material-you',
                  child: ListTile(
                    leading: const Icon(Icons.auto_awesome_outlined),
                    title: Text(S.of(context).settingsMaterialYouTitle),
                    subtitle:
                        Text(S.of(context).settingsMaterialYouSubtitle),
                    trailing: materialYouActive
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const Icon(Icons.circle_outlined),
                    onTap: _selectMaterialYou,
                  ),
                ),
              if (isAndroid) const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  S.of(context).settingsAccentPresetsHeader,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _presetHues.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    childAspectRatio: 1,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final hue = _presetHues[index];
                    final color =
                        HSLColor.fromAHSL(1, hue, 0.7, 0.5).toColor();
                    final selected = !materialYouActive &&
                        currentHue != null &&
                        (currentHue - hue).abs() < 0.5;
                    return Semantics(
                      identifier:
                          'accent-preset-${hue.round().toString().padLeft(3, '0')}',
                      child: InkWell(
                        onTap: () => _selectHue(hue),
                        customBorder: const CircleBorder(),
                        child: Container(
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: selected
                                ? Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface,
                                    width: 3,
                                  )
                                : null,
                          ),
                          child: selected
                              ? const Icon(
                                  Icons.check,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              Semantics(
                identifier: 'accent-custom-colour',
                child: ListTile(
                  leading: const Icon(Icons.colorize_outlined),
                  title: Text(S.of(context).settingsAccentCustomColour),
                  subtitle: Text(S.of(context).settingsAccentCustomSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openCustomColourDialog(currentHue),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openCustomColourDialog(double? initialHue) async {
    final picked = await showDialog<double?>(
      context: context,
      builder: (_) => _CustomColourDialog(initialHue: initialHue ?? 200),
    );
    if (picked != null) {
      _selectHue(picked);
    }
  }
}

class _CustomColourDialog extends StatefulWidget {
  final double initialHue;

  const _CustomColourDialog({required this.initialHue});

  @override
  State<_CustomColourDialog> createState() => _CustomColourDialogState();
}

class _CustomColourDialogState extends State<_CustomColourDialog> {
  late double _hue;

  @override
  void initState() {
    _hue = widget.initialHue;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final color = HSLColor.fromAHSL(1, _hue, 0.7, 0.5).toColor();
    return AlertDialog(
      title: Text(S.of(context).settingsAccentCustomColour),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            identifier: 'accent-custom-slider',
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 16,
                thumbColor: color,
                overlayColor: color.withValues(alpha: 0.2),
                trackShape: const _HueGradientTrackShape(_hueTrackColors),
              ),
              child: Slider(
                value: _hue,
                min: 0,
                max: 360,
                onChanged: (value) => setState(() => _hue = value),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.of(context).dialogCancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_hue),
          child: Text(S.of(context).dialogOKLabel),
        ),
      ],
    );
  }
}

const List<Color> _hueTrackColors = <Color>[
  Color(0xFFFF0000),
  Color(0xFFFFFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFF0000FF),
  Color(0xFFFF00FF),
  Color(0xFFFF0000),
];

class _HueGradientTrackShape extends RoundedRectSliderTrackShape {
  final List<Color> colors;
  const _HueGradientTrackShape(this.colors);

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final paint = Paint()
      ..shader = LinearGradient(colors: colors).createShader(trackRect);
    final rrect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackRect.height / 2),
    );
    context.canvas.drawRRect(rrect, paint);
  }
}
