import 'package:flutter/services.dart';

String keyChord(KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  return [
    if (keyboard.isControlPressed) 'ctrl',
    if (keyboard.isMetaPressed) 'meta',
    if (keyboard.isAltPressed) 'alt',
    if (keyboard.isShiftPressed) 'shift',
    event.logicalKey.keyLabel.toLowerCase(),
  ].join('+');
}
