// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math';

import 'package:ht_data_client/ht_data_client.dart';
import 'package:ht_shared/ht_shared.dart';

/// {@template ht_data_inmemory}
/// An in-memory implementation of [HtDataClient] for testing or local
/// development.
///
/// This client simulates a remote data source by storing data in memory.
/// It supports CRUD operations, querying, pagination, and user scoping.
///
/// **ID Management:** Relies on the provided `getId` function to extract
/// unique IDs from items. It does not generate IDs.
///
/// **Querying (`readAllByQuery`):**
/// - Matches against the JSON representation of items.
/// - **Nested Properties:** Supports dot-notation (e.g., `'category.id'`).
/// - **`_in` Suffix (Case-Insensitive):** For keys like `'category.id_in'`,
///   the query value is a comma-separated string. Checks if the item's
///   field value (lowercased string) is in the list of query values
///   (also lowercased).
/// - **`_contains` Suffix (Case-Insensitive):** For keys like
///   `'title_contains'`, performs a case-insensitive substring check.
///   If multiple `_contains` keys are provided (e.g. from a `q` param
///   searching multiple fields), they are ORed.
/// - **Exact Match:** For other keys, compares the item's field value
///   (as a string) with the query value (string).
/// - **Logic:** Non-`_contains` filters are ANDed. The result of this is
///   then ANDed with the result of ORing all `_contains` filters.
/// {@endtemplate}
class HtDataInMemory<T> implements HtDataClient<T> {
  /// {@macro ht_data_inmemory}
  HtDataInMemory({
    required ToJson<T> toJson,
    required String Function(T item) getId,
    List<T>? initialData,
  })  : _toJson = toJson,
        _getId = getId {
    // Initialize global storage once
    _userScopedStorage.putIfAbsent(_globalDataKey, () => <String, T>{});
    _userScopedJsonStorage.putIfAbsent(
      _globalDataKey,
      () => <String, Map<String, dynamic>>{},
    );

    if (initialData != null) {
      for (final item in initialData) {
        final id = _getId(item);
        if (_userScopedStorage[_globalDataKey]!.containsKey(id)) {
          throw ArgumentError('Duplicate ID "$id" found in initialData.');
        }
        _userScopedStorage[_globalDataKey]![id] = item;
        _userScopedJsonStorage[_globalDataKey]![id] = _toJson(item);
      }
    }
  }

  final ToJson<T> _toJson;
  final String Function(T item) _getId;

  static const String _globalDataKey = '__global_data__';

  // Stores original items, keyed by userId then itemId
  final Map<String, Map<String, T>> _userScopedStorage = {};
  // Stores JSON representations for querying, keyed by userId then itemId
  final Map<String, Map<String, Map<String, dynamic>>> _userScopedJsonStorage =
      {};

  Map<String, T> _getStorageForUser(String? userId) {
    final key = userId ?? _globalDataKey;
    return _userScopedStorage.putIfAbsent(key, () => <String, T>{});
  }

  Map<String, Map<String, dynamic>> _getJsonStorageForUser(String? userId) {
    final key = userId ?? _globalDataKey;
    return _userScopedJsonStorage.putIfAbsent(
      key,
      () => <String, Map<String, dynamic>>{},
    );
  }

  @override
  Future<SuccessApiResponse<T>> create({
    required T item,
    String? userId,
  }) async {
    final id = _getId(item);
    final userStorage = _getStorageForUser(userId);
    final userJsonStorage = _getJsonStorageForUser(userId);
    final scope = userId ?? 'global';
    print(
        'DEBUG: HtDataInMemory.create<$T> called for ID: "$id", user: "$scope"');

    if (userStorage.containsKey(id)) {
      print(
          'DEBUG: HtDataInMemory.create<$T> - Item with ID "$id" already exists for user "$scope".');
      throw BadRequestException(
        'Item with ID "$id" already exists for user "$scope".',
      );
    }

    userStorage[id] = item;
    userJsonStorage[id] = _toJson(item);
    print(
        'DEBUG: HtDataInMemory.create<$T> - Item ID: "$id" added for user: "$scope". Current items: ${userStorage.keys.length}');
    // await Future<void>.delayed(Duration.zero); // Simulate async
    return SuccessApiResponse(data: item);
  }

  @override
  Future<SuccessApiResponse<T>> read({
    required String id,
    String? userId,
  }) async {
    // await Future<void>.delayed(Duration.zero); // Simulate async
    final userStorage = _getStorageForUser(userId);
    final scope = userId ?? 'global';
    print(
        'DEBUG: HtDataInMemory.read<$T> called for ID: "$id", user: "$scope"');

    final item = userStorage[id];

    if (item == null) {
      print(
          'DEBUG: HtDataInMemory.read<$T> - Item ID: "$id" NOT FOUND for user: "$scope".');
      throw NotFoundException(
        'Item with ID "$id" not found for user "$scope".',
      );
    }
    print(
        'DEBUG: HtDataInMemory.read<$T> - Item ID: "$id" FOUND for user: "$scope".');
    return SuccessApiResponse(data: item);
  }

  @override
  Future<SuccessApiResponse<PaginatedResponse<T>>> readAll({
    String? userId,
    String? startAfterId,
    int? limit,
  }) async {
    // await Future<void>.delayed(Duration.zero); // Simulate async
    final userStorage = _getStorageForUser(userId);
    final allItems = userStorage.values.toList();

    final paginatedResponse = _createPaginatedResponse(
      allItems,
      startAfterId,
      limit,
    );
    return SuccessApiResponse(data: paginatedResponse);
  }

  dynamic _getNestedValue(Map<String, dynamic> item, String dotPath) {
    if (dotPath.isEmpty) return null;
    final parts = dotPath.split('.');
    dynamic currentValue = item;
    for (final part in parts) {
      if (currentValue is Map<String, dynamic> &&
          currentValue.containsKey(part)) {
        currentValue = currentValue[part];
      } else {
        return null; // Path not found or intermediate value is not a map
      }
    }
    return currentValue;
  }

  PaginatedResponse<T> _createPaginatedResponse(
    List<T> allMatchingItems,
    String? startAfterId,
    int? limit,
  ) {
    var startIndex = 0;
    if (startAfterId != null) {
      final index =
          allMatchingItems.indexWhere((item) => _getId(item) == startAfterId);
      if (index != -1) {
        startIndex = index + 1;
      } else {
        return const PaginatedResponse(items: [], cursor: null, hasMore: false);
      }
    }

    if (startIndex >= allMatchingItems.length) {
      return const PaginatedResponse(items: [], cursor: null, hasMore: false);
    }

    final actualLimit = limit ?? allMatchingItems.length;
    final count = min(actualLimit, allMatchingItems.length - startIndex);
    final endIndex = startIndex + count;
    final pageItems = allMatchingItems.sublist(startIndex, endIndex);

    final hasMore = endIndex < allMatchingItems.length;
    final cursor =
        (pageItems.isNotEmpty && hasMore) ? _getId(pageItems.last) : null;

    return PaginatedResponse(
      items: pageItems,
      cursor: cursor,
      hasMore: hasMore,
    );
  }

  /// Transforms raw query parameters (like those from URL queries) into the
  /// internal format expected by the in-memory client's filtering logic.
  ///
  /// This method mimics the query translation performed by the `ht-api`
  /// backend's data route handlers, allowing the `HtDataInMemoryClient` to
  /// directly consume queries from the Flutter app's `HeadlinesFeedBloc`.
  Map<String, dynamic> _transformQuery(Map<String, dynamic> rawQuery) {
    // DEBUG: Log the raw query received by _transformQuery
    print('DEBUG: _transformQuery received rawQuery: $rawQuery');

    final transformed = <String, dynamic>{};

    // Always pass through pagination parameters directly.
    // These are expected to be already present in rawQuery if applicable.
    if (rawQuery.containsKey('startAfterId')) {
      transformed['startAfterId'] = rawQuery['startAfterId'];
    }
    if (rawQuery.containsKey('limit')) {
      transformed['limit'] = rawQuery['limit'];
    }

    // Determine the model type at runtime to apply specific transformations.
    // This makes the generic client behave correctly for known model types.
    // Using `T == SomeType` for correct generic type comparison.
    // DEBUG: Log the detected generic type T
    print('DEBUG: _transformQuery detected generic type T: $T');

    Set<String> allowedKeys;
    String? modelNameForError;

    if (T == Headline) {
      modelNameForError = 'headline';
      allowedKeys = {'categories', 'sources', 'q'};
      final qValue = rawQuery['q'] as String?;
      if (qValue != null && qValue.isNotEmpty) {
        transformed['title_contains'] = qValue;
        // DEBUG: Applied q filter for Headline
        print('DEBUG: Headline: Applied title_contains for q: $qValue');
      } else {
        final categories = rawQuery['categories'] as String?;
        if (categories != null && categories.isNotEmpty) {
          transformed['category.id_in'] = categories;
          // DEBUG: Applied categories filter for Headline
          print('DEBUG: Headline: Applied category.id_in: $categories');
        }
        final sources = rawQuery['sources'] as String?;
        if (sources != null && sources.isNotEmpty) {
          transformed['source.id_in'] = sources;
          // DEBUG: Applied sources filter for Headline
          print('DEBUG: Headline: Applied source.id_in: $sources');
        }
      }
    } else if (T == Source) {
      modelNameForError = 'source';
      allowedKeys = {'countries', 'sourceTypes', 'languages', 'q'};
      final qValue = rawQuery['q'] as String?;
      if (qValue != null && qValue.isNotEmpty) {
        transformed['name_contains'] = qValue;
        // DEBUG: Applied q filter for Source
        print('DEBUG: Source: Applied name_contains for q: $qValue');
      } else {
        final countries = rawQuery['countries'] as String?;
        if (countries != null && countries.isNotEmpty) {
          transformed['headquarters.iso_code_in'] = countries;
          // DEBUG: Applied countries filter for Source
          print('DEBUG: Source: Applied headquarters.iso_code_in: $countries');
        }
        final sourceTypes = rawQuery['sourceTypes'] as String?;
        if (sourceTypes != null && sourceTypes.isNotEmpty) {
          transformed['source_type_in'] = sourceTypes;
          // DEBUG: Applied sourceTypes filter for Source
          print('DEBUG: Source: Applied source_type_in: $sourceTypes');
        }
        final languages = rawQuery['languages'] as String?;
        if (languages != null && languages.isNotEmpty) {
          transformed['language_in'] = languages;
          // DEBUG: Applied languages filter for Source
          print('DEBUG: Source: Applied language_in: $languages');
        }
      }
    } else if (T == Category) {
      modelNameForError = 'category';
      allowedKeys = {'q'};
      final qValue = rawQuery['q'] as String?;
      if (qValue != null && qValue.isNotEmpty) {
        transformed['name_contains'] = qValue;
        // DEBUG: Applied q filter for Category
        print('DEBUG: Category: Applied name_contains for q: $qValue');
      }
    } else if (T == Country) {
      modelNameForError = 'country';
      allowedKeys = {'q'};
      final qValue = rawQuery['q'] as String?;
      if (qValue != null && qValue.isNotEmpty) {
        transformed['name_contains'] = qValue;
        transformed['iso_code_contains'] = qValue;
        // DEBUG: Applied q filter for Country (name and iso_code)
        print(
          'DEBUG: Country: Applied name_contains and iso_code_contains for q: $qValue',
        );
      }
    } else {
      // For other models (e.g., User, UserAppSettings, AppConfig),
      // pass through all non-standard query params directly.
      // This assumes they are already in the correct format for exact match.
      allowedKeys = rawQuery.keys.toSet()..removeAll({'startAfterId', 'limit'});
      rawQuery.forEach((key, value) {
        if (key != 'startAfterId' && key != 'limit') {
          transformed[key] = value;
        }
      });
    }

    // Validate received keys against allowed keys for the specific models
    final receivedKeysForValidation = rawQuery.keys.toSet()
      ..removeAll({'startAfterId', 'limit', 'model'});

    if (modelNameForError != null) {
      for (final key in receivedKeysForValidation) {
        if (!allowedKeys.contains(key)) {
          // DEBUG: Log invalid query parameter
          print(
            'DEBUG: Invalid query parameter "$key" for model "$modelNameForError". '
            'Allowed parameters are: ${allowedKeys.join(', ')}.',
          );
          throw BadRequestException(
            'Invalid query parameter "$key" for model "$modelNameForError". '
            'Allowed parameters are: ${allowedKeys.join(', ')}.',
          );
        }
      }
    }

    // DEBUG: Log the final transformed query
    print('DEBUG: _transformQuery returning transformed: $transformed');
    return transformed;
  }

  @override
  Future<SuccessApiResponse<PaginatedResponse<T>>> readAllByQuery(
    Map<String, dynamic> query, {
    String? userId,
    String? startAfterId,
    int? limit,
  }) async {
    // await Future<void>.delayed(Duration.zero);

    final userJsonStorage = _getJsonStorageForUser(userId);
    final userStorage = _getStorageForUser(userId);

    // Transform the incoming query parameters before processing
    final transformedQuery = _transformQuery(query);

    if (transformedQuery.isEmpty) {
      final allItems = userStorage.values.toList();
      final paginatedResp =
          _createPaginatedResponse(allItems, startAfterId, limit);
      return SuccessApiResponse(data: paginatedResp);
    }

    final matchedItems = <T>[];
    userJsonStorage.forEach((itemId, Map<String, dynamic> jsonItem) {
      final containsFilters = <MapEntry<String, String>>[];
      final otherFilters = <String, String>{};

      // Use transformedQuery for filtering
      transformedQuery.forEach((key, value) {
        if (key.endsWith('_contains')) {
          containsFilters.add(MapEntry(key, value as String));
        } else if (key != 'startAfterId' && key != 'limit') {
          // Exclude pagination params from otherFilters
          otherFilters[key] = value as String;
        }
      });

      var matchesOtherFilters = true;
      if (otherFilters.isNotEmpty) {
        otherFilters.forEach((filterKey, filterValueStr) {
          if (!matchesOtherFilters) return;

          var actualPath = filterKey;
          var operation = 'exact';

          if (filterKey.endsWith('_in')) {
            actualPath = filterKey.substring(0, filterKey.length - 3);
            operation = 'in';
          }

          final dynamic actualItemValue = _getNestedValue(jsonItem, actualPath);

          switch (operation) {
            case 'in':
              if (actualItemValue == null) {
                matchesOtherFilters = false;
              } else {
                final expectedQueryValues = filterValueStr
                    .split(',')
                    .map((e) => e.trim().toLowerCase())
                    .where((e) => e.isNotEmpty)
                    .toList();
                if (expectedQueryValues.isEmpty && filterValueStr.isNotEmpty) {
                  matchesOtherFilters = false;
                } else if (actualItemValue is List) {
                  final actualListStr = actualItemValue
                      .map((e) => e.toString().toLowerCase())
                      .toList();
                  final foundMatchInList =
                      expectedQueryValues.any(actualListStr.contains);
                  if (!foundMatchInList) {
                    matchesOtherFilters = false;
                  }
                } else {
                  if (!expectedQueryValues
                      .contains(actualItemValue.toString().toLowerCase())) {
                    matchesOtherFilters = false;
                  }
                }
              }
            case 'exact':
            default:
              if (actualItemValue == null) {
                if (filterValueStr != 'null') {
                  matchesOtherFilters = false;
                }
              } else if (actualItemValue.toString() != filterValueStr) {
                matchesOtherFilters = false;
              }
          }
        });
      }

      var matchesAnyContains = false;
      if (containsFilters.isNotEmpty) {
        for (final entry in containsFilters) {
          final filterKey = entry.key;
          final filterValueStr = entry.value;
          final actualPath = filterKey.substring(0, filterKey.length - 9);
          final dynamic actualItemValue = _getNestedValue(jsonItem, actualPath);

          if (actualItemValue != null &&
              actualItemValue
                  .toString()
                  .toLowerCase()
                  .contains(filterValueStr.toLowerCase())) {
            matchesAnyContains = true;
            break;
          }
        }
      }

      if (matchesOtherFilters &&
          (containsFilters.isEmpty || matchesAnyContains)) {
        final originalItem = userStorage[itemId];
        if (originalItem != null) {
          matchedItems.add(originalItem);
        }
      }
    });

    // Extract pagination parameters from the original query, not the transformed one
    final finalStartAfterId = query['startAfterId'] as String?;
    final finalLimit =
        query['limit'] != null ? int.tryParse(query['limit'] as String) : null;

    final paginatedResponse =
        _createPaginatedResponse(matchedItems, finalStartAfterId, finalLimit);
    return SuccessApiResponse(data: paginatedResponse);
  }

  @override
  Future<SuccessApiResponse<T>> update({
    required String id,
    required T item,
    String? userId,
  }) async {
    final userStorage = _getStorageForUser(userId);
    final userJsonStorage = _getJsonStorageForUser(userId);
    final scope = userId ?? 'global';
    print(
        'DEBUG: HtDataInMemory.update<$T> called for ID: "$id", user: "$scope"');

    if (!userStorage.containsKey(id)) {
      print(
          'DEBUG: HtDataInMemory.update<$T> - Item ID: "$id" NOT FOUND for update for user: "$scope".');
      throw NotFoundException(
        'Item with ID "$id" not found for update for user "$scope".',
      );
    }

    final incomingId = _getId(item);
    if (incomingId != id) {
      print(
          'DEBUG: HtDataInMemory.update<$T> - ID mismatch: incoming "$incomingId", path "$id" for user: "$scope".');
      throw BadRequestException(
        'Item ID ("$incomingId") does not match path ID ("$id") for "$scope".',
      );
    }

    userStorage[id] = item;
    userJsonStorage[id] = _toJson(item);
    print(
        'DEBUG: HtDataInMemory.update<$T> - Item ID: "$id" updated for user: "$scope".');
    // await Future<void>.delayed(Duration.zero);
    return SuccessApiResponse(data: item);
  }

  @override
  Future<void> delete({
    required String id,
    String? userId,
  }) async {
    // await Future<void>.delayed(Duration.zero);
    final userStorage = _getStorageForUser(userId);
    final userJsonStorage = _getJsonStorageForUser(userId);
    final scope = userId ?? 'global';
    print(
        'DEBUG: HtDataInMemory.delete<$T> called for ID: "$id", user: "$scope"');

    if (!userStorage.containsKey(id)) {
      print(
          'DEBUG: HtDataInMemory.delete<$T> - Item ID: "$id" NOT FOUND for deletion for user: "$scope".');
      throw NotFoundException(
        'Item with ID "$id" not found for deletion for user "$scope".',
      );
    }
    userStorage.remove(id);
    userJsonStorage.remove(id);
    print(
        'DEBUG: HtDataInMemory.delete<$T> - Item ID: "$id" deleted for user: "$scope". Current items: ${userStorage.keys.length}');
  }
}
