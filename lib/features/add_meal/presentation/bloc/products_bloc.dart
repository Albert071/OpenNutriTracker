import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/usecase/search_products_usecase.dart';
import 'package:opennutritracker/features/add_meal/presentation/bloc/search_debounce.dart';

part 'products_event.dart';

part 'products_state.dart';

class ProductsBloc extends Bloc<ProductsEvent, ProductsState> {
  final log = Logger('ProductsBloc');

  final SearchProductsUseCase _searchProductUseCase;
  final GetConfigUsecase _getConfigUsecase;

  String _searchString = "";

  ProductsBloc(this._searchProductUseCase, this._getConfigUsecase)
      : super(ProductsInitial()) {
    on<LoadProductsEvent>(
      (event, emit) =>
          _loadProducts(event.searchString, emit, skipRemote: false, force: true),
    );
    on<SearchInputChangedEvent>(
      (event, emit) => _loadProducts(
        event.searchString,
        emit,
        skipRemote: event.searchString.trim().length < minRemoteQueryLength,
      ),
      transformer: debounceRestartable(searchDebounceDuration),
    );
    on<RefreshProductsEvent>((event, emit) async {
      emit(ProductsLoadingState());
      try {
        final result = await _searchProductUseCase.searchOFFProductsByString(
          _searchString,
        );
        emit(ProductsLoadedState(
          products: result.meals,
          remoteSourceEmpty: result.remoteSourceEmpty,
        ));
      } catch (error) {
        log.severe(error);
        emit(ProductsFailedState());
      }
    });
  }

  /// Shared search routine for the immediate and debounced events.
  ///
  /// [skipRemote] limits the search to local matches (used for short
  /// as-you-type queries). [force] runs even when the query is unchanged —
  /// set on the immediate path so an explicit submit always re-queries the
  /// remote source even if a debounced local-only search ran for the same
  /// text. A fresh search keeps any existing results on screen rather than
  /// blanking to a spinner, so typing doesn't flicker.
  Future<void> _loadProducts(
    String searchString,
    Emitter<ProductsState> emit, {
    required bool skipRemote,
    bool force = false,
  }) async {
    if (!force && searchString == _searchString) return;
    _searchString = searchString;
    if (state is! ProductsLoadedState) {
      emit(ProductsLoadingState());
    }
    try {
      final result = await _searchProductUseCase.searchOFFProductsByString(
        searchString,
        skipRemote: skipRemote,
      );
      final config = await _getConfigUsecase.getConfig();
      emit(
        ProductsLoadedState(
          products: result.meals,
          usesImperialUnits: config.usesImperialUnits,
          remoteSourceEmpty: result.remoteSourceEmpty,
        ),
      );
    } catch (error) {
      log.severe(error);
      emit(ProductsFailedState());
    }
  }
}
