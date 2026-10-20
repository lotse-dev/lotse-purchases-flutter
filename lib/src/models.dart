import 'package:flutter/foundation.dart';

/// What a product is in its store.
enum LotseProductKind {
  /// Renews until cancelled.
  subscription,

  /// Bought once, kept forever.
  nonConsumable,

  /// Bought again and again (coins); unlocks no entitlement.
  consumable,
}

/// A product the app offers: configured in the Lotse console, with price and
/// title from the store on this device.
@immutable
class LotseProduct {
  /// Creates a product. Apps get products from `LotsePurchases.products()`.
  const LotseProduct({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.title,
    required this.description,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
    required this.entitlements,
    this.basePlanId,
    this.period,
    this.handle,
  });

  /// The product id in the store.
  final String id;

  /// Google subscriptions: the base plan; null otherwise.
  final String? basePlanId;
  final LotseProductKind kind;

  /// The name your team gave the product in the console.
  final String displayName;

  /// Title and description as the store shows them, in the user's language.
  final String title;
  final String description;

  /// The price formatted by the store, e.g. `4,99 €`.
  final String price;

  /// The price as a number, for comparisons ("save 20 %").
  final double rawPrice;
  final String currencyCode;

  /// ISO 8601 duration of one period (`P1M`, `P1Y`); null for one-time
  /// purchases.
  final String? period;

  /// Keys of the entitlements the product unlocks, e.g. `{'pro'}`.
  final Set<String> entitlements;

  /// The store's own object behind the product. Internal.
  final Object? handle;

  @override
  String toString() =>
      'LotseProduct($id${basePlanId == null ? '' : '/$basePlanId'})';
}

/// One entitlement the customer has now.
@immutable
class LotseEntitlement {
  /// Creates an entitlement.
  const LotseEntitlement({
    required this.key,
    this.expiresAt,
    this.willRenew = false,
    this.granted = false,
    this.provisional = false,
  });

  /// The key, e.g. `pro`.
  final String key;

  /// When access ends without a renewal; null for a lifetime purchase or a
  /// grant without end.
  final DateTime? expiresAt;

  /// The subscription behind it renews.
  final bool willRenew;

  /// Given by your team (console or server API), not bought.
  final bool granted;

  /// From a fresh purchase that Lotse could not check yet: valid for 24
  /// hours on the store's word, then only when Lotse confirms it.
  final bool provisional;

  /// Whether the entitlement still gives access at [now].
  bool isActiveAt(DateTime now) => expiresAt == null || expiresAt!.isAfter(now);

  Map<String, Object?> toJson() => {
    'key': key,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'willRenew': willRenew,
    'granted': granted,
    'provisional': provisional,
  };

  static LotseEntitlement? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    if (key is! String || key.isEmpty) return null;
    final expires = json['expiresAt'];
    return LotseEntitlement(
      key: key,
      expiresAt: expires is String ? DateTime.tryParse(expires)?.toUtc() : null,
      willRenew: json['willRenew'] == true,
      granted: json['granted'] == true,
      provisional: json['provisional'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LotseEntitlement &&
      other.key == key &&
      other.expiresAt == expiresAt &&
      other.willRenew == willRenew &&
      other.granted == granted &&
      other.provisional == provisional;

  @override
  int get hashCode =>
      Object.hash(key, expiresAt, willRenew, granted, provisional);

  @override
  String toString() => 'LotseEntitlement($key)';
}

/// The entitlements of the customer: what `hasEntitlement` answers from.
@immutable
class LotseEntitlements {
  /// Creates the set; [all] may contain expired ones, [active] filters.
  LotseEntitlements(Iterable<LotseEntitlement> all)
    : all = List.unmodifiable(all);

  /// None.
  static final empty = LotseEntitlements(const []);

  /// Every entitlement as last known, also expired ones.
  final List<LotseEntitlement> all;

  /// The keys active at [now].
  Set<String> activeAt(DateTime now) => {
    for (final e in all)
      if (e.isActiveAt(now)) e.key,
  };

  /// The entitlement with [key] active at [now], the longest one if several.
  LotseEntitlement? entitlementAt(String key, DateTime now) {
    LotseEntitlement? best;
    for (final e in all) {
      if (e.key != key || !e.isActiveAt(now)) continue;
      if (best == null ||
          e.expiresAt == null ||
          (best.expiresAt != null && e.expiresAt!.isAfter(best.expiresAt!))) {
        best = e;
      }
    }
    return best;
  }

  @override
  bool operator ==(Object other) =>
      other is LotseEntitlements && listEquals(other.all, all);

  @override
  int get hashCode => Object.hashAll(all);
}

/// The outcome of `LotsePurchases.buy`.
sealed class LotsePurchaseResult {
  const LotsePurchaseResult();
}

/// Bought. [entitlements] are the customer's afterwards; with [provisional]
/// Lotse could not check the purchase yet and grants it for 24 hours on the
/// store's word.
final class LotsePurchaseSuccess extends LotsePurchaseResult {
  const LotsePurchaseSuccess(this.entitlements, {this.provisional = false});

  final LotseEntitlements entitlements;
  final bool provisional;
}

/// The user closed the store dialog.
final class LotsePurchaseCancelled extends LotsePurchaseResult {
  const LotsePurchaseCancelled();
}

/// The store waits for something (a parent's approval, a cash payment). The
/// entitlements stream reports the purchase once it goes through.
final class LotsePurchasePending extends LotsePurchaseResult {
  const LotsePurchasePending();
}

/// Why a purchase failed.
enum LotsePurchaseFailure {
  /// The store is not available on this device (web, no store account).
  storeUnavailable,

  /// The store refused or failed.
  storeError,

  /// Lotse refused the purchase: the app is not set up for this store, or
  /// the purchase belongs to another customer of the app.
  rejected,
}

/// The purchase did not go through. [message] is for logs, not for users.
final class LotsePurchaseFailed extends LotsePurchaseResult {
  const LotsePurchaseFailed(this.failure, [this.message]);

  final LotsePurchaseFailure failure;
  final String? message;
}
