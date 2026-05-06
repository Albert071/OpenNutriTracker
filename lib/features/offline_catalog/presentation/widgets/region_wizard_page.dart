import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/country_taxonomy_entry.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';

/// Country selection page. Shows the OFF taxonomy as a scrollable list
/// of FilterChips, sorted by product count descending, with a search
/// field that narrows the visible list as the user types.
///
/// Selected country tags propagate up to the orchestrator via
/// [onSelectionChanged] so the wizard's footer button can stay
/// disabled until at least one country is chosen.
class RegionWizardPage extends StatefulWidget {
  final Set<String> initialSelection;
  final ValueChanged<Set<String>> onSelectionChanged;

  const RegionWizardPage({
    super.key,
    required this.initialSelection,
    required this.onSelectionChanged,
  });

  @override
  State<RegionWizardPage> createState() => _RegionWizardPageState();
}

class _RegionWizardPageState extends State<RegionWizardPage> {
  late Set<String> _selected;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelection};
  }

  void _toggle(String code) {
    setState(() {
      if (_selected.contains(code)) {
        _selected.remove(code);
      } else {
        _selected.add(code);
      }
    });
    widget.onSelectionChanged(_selected);
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<OfflineCatalogBloc, OfflineCatalogState>(
      builder: (context, state) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // l10n: offlineCatalogRegionTitle
              Text(
                'Pick your countries',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              // l10n: offlineCatalogRegionBody
              Text(
                'Only products tagged with the countries you choose '
                'will be downloaded. Counts come from Open Food Facts '
                'and update over time.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (state.countriesFromFallback) _buildFallbackBanner(context),
              _buildSearchField(),
              const SizedBox(height: 12),
              Expanded(
                child: _buildBody(context, state),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFallbackBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          // l10n: offlineCatalogRegionFallbackNotice
          const Expanded(
            child: Text(
              'Showing a short fallback list because we could not '
              'reach Open Food Facts. Connect to the internet and '
              'refresh to load the full country list.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      onChanged: (value) => setState(() => _searchQuery = value.trim()),
      decoration: InputDecoration(
        // l10n: offlineCatalogRegionSearchHint
        hintText: 'Search countries',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh country list',
          onPressed: () {
            context
                .read<OfflineCatalogBloc>()
                .add(const LoadCountriesEvent(forceRefresh: true));
          },
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, OfflineCatalogState state) {
    if (state.phase == OfflineCatalogPhase.loadingCountries) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = state.countries;
    if (all == null || all.isEmpty) {
      // l10n: offlineCatalogRegionEmpty
      return const Center(child: Text('No countries to show'));
    }
    final visible = _filter(all, _searchQuery);
    if (visible.isEmpty) {
      // l10n: offlineCatalogRegionNoMatches
      return const Center(child: Text('No countries match your search'));
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        final selected = _selected.contains(entry.code);
        return ListTile(
          dense: true,
          title: Text(entry.name),
          subtitle: Text(_formatCount(entry.productCount)),
          trailing: Checkbox(
            value: selected,
            onChanged: (_) => _toggle(entry.code),
          ),
          onTap: () => _toggle(entry.code),
        );
      },
    );
  }

  List<CountryTaxonomyEntry> _filter(
    List<CountryTaxonomyEntry> all,
    String query,
  ) {
    if (query.isEmpty) return all;
    final q = query.toLowerCase();
    return all.where((e) => e.name.toLowerCase().contains(q)).toList();
  }

  String _formatCount(int count) {
    // l10n: offlineCatalogRegionCount (formatter)
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M products';
    }
    if (count >= 1000) {
      return '${(count / 1000).round()}k products';
    }
    return '$count products';
  }
}
