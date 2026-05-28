import 'package:flutter/material.dart';
import 'package:opennutritracker/core/utils/custom_icons.dart';
import 'package:opennutritracker/generated/l10n.dart';

class MealSearchBar extends StatelessWidget {
  final ValueNotifier<String> searchStringListener;
  final Function(String) onSearchSubmit;
  // Fired on every keystroke for debounced search-as-you-type. Optional so
  // callers that only want submit-on-enter can omit it.
  final Function(String)? onSearchChanged;
  // Nullable so callers that don't surface a barcode flow (e.g. the recipe
  // ingredient picker) can omit the suffix icon entirely.
  final Function()? onBarcodePressed;

  final _searchTextController = TextEditingController();

  MealSearchBar({
    super.key,
    required this.searchStringListener,
    required this.onSearchSubmit,
    required this.onBarcodePressed,
    this.onSearchChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          flex: 1,
          child: TextField(
            controller: _searchTextController,
            textInputAction: TextInputAction.search,
            onChanged: (input) {
              searchStringListener.value = input;
              onSearchChanged?.call(input);
            },
            onSubmitted: onSearchSubmit,
            decoration: InputDecoration(
              hintText: S.of(context).searchLabel,
              prefixIcon: const Icon(Icons.search_outlined),
              suffixIcon: onBarcodePressed != null
                  ? IconButton(
                      icon: const Icon(CustomIcons.barcode_scan),
                      onPressed: onBarcodePressed,
                    )
                  : null,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8.0),
        IconButton(
          onPressed: () {
            FocusManager.instance.primaryFocus?.unfocus(); // Hide Keyboard
            onSearchSubmit(_searchTextController.text);
          },
          icon: const Icon(Icons.search_outlined),
          style: IconButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        ),
      ],
    );
  }
}
