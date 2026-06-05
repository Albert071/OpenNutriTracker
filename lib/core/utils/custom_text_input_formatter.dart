import 'package:flutter/services.dart';

class CustomTextInputFormatter {
  /// Allows a decimal number with at most [maxDecimals] places (comma or
  /// period), normalising the separator to a period. Defaults to two decimals
  /// so every food-quantity field accepts the same precision; pass a different
  /// limit only where a field genuinely needs more.
  static List<TextInputFormatter> doubleOnly({int maxDecimals = 2}) =>
      <TextInputFormatter>[
        FilteringTextInputFormatter.allow(
          RegExp('^\\d+([.,]\\d{0,$maxDecimals})?\$'),
        ),
        TextInputFormatter.withFunction(
          (oldValue, newValue) =>
              newValue.copyWith(text: newValue.text.replaceAll(',', '.')),
        ),
      ];
}
