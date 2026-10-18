import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repository.dart';
import '../../domain/catalog.dart';

/// Teams, people and seats including the inactive ones. The repository
/// emits again after every admin write, so the screen follows each save.
final adminCatalogProvider = StreamProvider.autoDispose<Catalog>(
  (ref) => ref.watch(repositoryProvider).watchCatalog(includeInactive: true),
);

/// Plain words for any failure of an admin call.
String adminErrorText(Object e) {
  if (e is RepositoryException) return e.message;
  if (e is NetworkException) {
    return 'No connection. Check your internet and try again.';
  }
  return 'Something went wrong. Try again.';
}
