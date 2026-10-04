import 'package:flutter/material.dart';

Color? parseHexColor(String value) {
  var hex = value.trim().replaceFirst('#', '');
  if (!RegExp(
    r'^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
  ).hasMatch(hex)) {
    return null;
  }
  if (hex.length <= 4) hex = hex.split('').map((c) => '$c$c').join();
  final rgb = int.parse(hex.substring(0, 6), radix: 16);
  final alpha = hex.length == 8 ? int.parse(hex.substring(6), radix: 16) : 255;
  return Color((alpha << 24) | rgb);
}

String colorHex(Color color, {required bool alpha}) {
  final value = color.toARGB32();
  final rgb = (value & 0xffffff).toRadixString(16).padLeft(6, '0');
  final opacity = ((value >> 24) & 255).toRadixString(16).padLeft(2, '0');
  return '#$rgb${alpha ? opacity : ''}';
}

class HexColorPicker extends StatefulWidget {
  const HexColorPicker({super.key, required this.hex});
  final String hex;
  @override
  State<HexColorPicker> createState() => _HexColorPickerState();
}

class _HexColorPickerState extends State<HexColorPicker> {
  late HSVColor hsv = HSVColor.fromColor(parseHexColor(widget.hex)!);
  late bool alpha = widget.hex.length == 5 || widget.hex.length == 9;
  late final input = TextEditingController(text: widget.hex);
  String? error;
  void update(HSVColor value) => setState(() {
    hsv = value;
    input.text = colorHex(hsv.toColor(), alpha: alpha);
    error = null;
  });
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Widget control(
    String label,
    double value,
    double max,
    ValueChanged<double> change,
  ) => Row(
    children: [
      SizedBox(width: 78, child: Text(label)),
      Expanded(
        child: Slider(value: value, min: 0, max: max, onChanged: change),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Choose color'),
    content: SizedBox(
      width: 380,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 52,
              width: double.infinity,
              decoration: BoxDecoration(
                color: hsv.toColor(),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: input,
              decoration: InputDecoration(
                labelText: 'HEX (RGB / RGBA)',
                errorText: error,
              ),
              onChanged: (text) {
                final color = parseHexColor(text);
                setState(() {
                  error = color == null
                      ? 'Use #RGB, #RGBA, #RRGGBB or #RRGGBBAA'
                      : null;
                  if (color != null) {
                    hsv = HSVColor.fromColor(color);
                    alpha =
                        text.trim().replaceFirst('#', '').length == 4 ||
                        text.trim().replaceFirst('#', '').length == 8;
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                const height = 190.0;
                final width = constraints.maxWidth;
                void pick(Offset point) => update(
                  hsv
                      .withSaturation((point.dx / width).clamp(0.0, 1.0))
                      .withValue((1 - point.dy / height).clamp(0.0, 1.0)),
                );
                return Semantics(
                  label: 'Color palette: saturation and brightness',
                  child: GestureDetector(
                    onTapDown: (event) => pick(event.localPosition),
                    onPanStart: (event) => pick(event.localPosition),
                    onPanUpdate: (event) => pick(event.localPosition),
                    child: SizedBox(
                      height: height,
                      width: width,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white,
                                      HSVColor.fromAHSV(
                                        1,
                                        hsv.hue,
                                        1,
                                        1,
                                      ).toColor(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: (hsv.saturation * width - 7).clamp(
                                0.0,
                                width - 14,
                              ),
                              top: ((1 - hsv.value) * height - 7).clamp(
                                0.0,
                                height - 14,
                              ),
                              child: IgnorePointer(
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black54,
                                        blurRadius: 2,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                void pick(Offset point) => update(
                  hsv.withHue((point.dx / width).clamp(0.0, 1.0) * 360),
                );
                return Semantics(
                  label: 'Hue spectrum',
                  child: GestureDetector(
                    onTapDown: (event) => pick(event.localPosition),
                    onPanStart: (event) => pick(event.localPosition),
                    onPanUpdate: (event) => pick(event.localPosition),
                    child: SizedBox(
                      height: 24,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                gradient: LinearGradient(
                                  colors: [
                                    for (final hue in [
                                      0.0,
                                      60.0,
                                      120.0,
                                      180.0,
                                      240.0,
                                      300.0,
                                      360.0,
                                    ])
                                      HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: (hsv.hue / 360 * width - 3).clamp(
                              0.0,
                              width - 6,
                            ),
                            top: 0,
                            bottom: 0,
                            child: IgnorePointer(
                              child: Container(
                                width: 6,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 2,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            control('Opacity', hsv.alpha, 1, (v) {
              alpha = true;
              update(hsv.withAlpha(v));
            }),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in [
                  Colors.black,
                  Colors.white,
                  const Color(0xff42a5ff),
                  Colors.red,
                  Colors.orange,
                  Colors.yellow,
                  Colors.green,
                  Colors.purple,
                ])
                  Tooltip(
                    message: colorHex(color, alpha: false),
                    child: InkWell(
                      onTap: () => update(
                        HSVColor.fromColor(color).withAlpha(hsv.alpha),
                      ),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: color,
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: error != null
            ? null
            : () =>
                  Navigator.pop(context, colorHex(hsv.toColor(), alpha: alpha)),
        child: const Text('Apply'),
      ),
    ],
  );
}
