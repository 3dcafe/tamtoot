import 'package:flutter/material.dart';

Color? parseHexColor(String value) {
  var hex = value.trim().replaceFirst('#', '');
  if (!RegExp(
    r'^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
  ).hasMatch(hex))
    return null;
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
            control('Hue', hsv.hue, 360, (v) => update(hsv.withHue(v))),
            control(
              'Saturation',
              hsv.saturation,
              1,
              (v) => update(hsv.withSaturation(v)),
            ),
            control(
              'Brightness',
              hsv.value,
              1,
              (v) => update(hsv.withValue(v)),
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
