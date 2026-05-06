import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/features/offline_catalog/domain/entity/country_taxonomy_entry.dart';
import 'package:opennutritracker/features/offline_catalog/presentation/bloc/offline_catalog_bloc.dart';
import 'package:opennutritracker/generated/l10n.dart';

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
        final s = S.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s.offlineCatalogRegionTitle,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                s.offlineCatalogRegionBody,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (state.countriesFromFallback) _buildFallbackBanner(context),
              _buildSearchField(context),
              const SizedBox(height: 12),
              Expanded(child: _buildBody(context, state)),
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
          Expanded(
            child: Text(S.of(context).offlineCatalogRegionFallbackNotice),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final s = S.of(context);
    return TextField(
      onChanged: (value) => setState(() => _searchQuery = value.trim()),
      decoration: InputDecoration(
        hintText: s.offlineCatalogRegionSearchHint,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: s.offlineCatalogRegionRefreshTooltip,
          onPressed: () {
            context
                .read<OfflineCatalogBloc>()
                .add(const LoadCountriesEvent(forceRefresh: true));
          },
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildBody(BuildContext context, OfflineCatalogState state) {
    final s = S.of(context);
    if (state.phase == OfflineCatalogPhase.loadingCountries) {
      return const Center(child: CircularProgressIndicator());
    }
    final all = state.countries;
    if (all == null || all.isEmpty) {
      return Center(child: Text(s.offlineCatalogRegionEmpty));
    }
    final visible = _filter(all, _searchQuery);
    if (visible.isEmpty) {
      return Center(child: Text(s.offlineCatalogRegionNoMatches));
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        final selected = _selected.contains(entry.code);
        return ListTile(
          dense: true,
          title: Text(entry.name),
          subtitle: Text(_formatCount(context, entry.productCount)),
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

  String _formatCount(BuildContext context, int count) {
    final compact = count >= 1000000
        ? '${(count / 1000000).toStringAsFixed(1)}M'
        : count >= 1000
            ? '${(count / 1000).round()}k'
            : count.toString();
    return S.of(context).offlineCatalogProductCount(compact);
  }
}
