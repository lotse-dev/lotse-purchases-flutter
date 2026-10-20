import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:lotse/lotse_internal.dart' show PurchaseStore;

/// What happened to a purchase in the store.
enum StorePurchaseStatus { pending, purchased, restored, error, canceled }

/// A purchase as the store reports it, reduced to what Lotse needs.
@immutable
class StorePurchase {
  const StorePurchase({
    required this.productId,
    required this.storeRef,
    required this.status,
    required this.needsCompletion,
    this.transactionDate,
    this.error,
    this.handle,
  });

  final String productId;

  /// What Lotse checks the purchase with: Google's purchase token, Apple's
  /// transaction id.
  final String storeRef;
  final StorePurchaseStatus status;

  /// The store waits for `complete` (Google acknowledgement, StoreKit
  /// `finish`).
  final bool needsCompletion;
  final DateTime? transactionDate;
  final String? error;

  /// The plugin's object, for `complete`.
  final Object? handle;
}

/// A product as the store offers it on this device.
@immutable
class StoreOffer {
  const StoreOffer({
    required this.productId,
    required this.title,
    required this.description,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
    this.basePlanId,
    this.offerId,
    this.handle,
  });

  final String productId;

  /// Google subscriptions: base plan and offer of this entry.
  final String? basePlanId;
  final String? offerId;
  final String title;
  final String description;
  final String price;
  final double rawPrice;
  final String currencyCode;
  final Object? handle;
}

/// The store, behind one seam so tests run without the plugin.
abstract interface class PurchaseStoreGateway {
  /// The store this device buys in; null where there is none (web, desktop
  /// other than macOS).
  PurchaseStore? get store;

  Future<bool> isAvailable();

  /// Every purchase update: new purchases, restored ones, unfinished ones the
  /// store hands over again at start.
  Stream<List<StorePurchase>> get purchases;

  Future<List<StoreOffer>> query(Set<String> productIds);

  /// Opens the store dialog. False when it could not be opened. [accountToken]
  /// is the customer's UUID: Google `obfuscatedAccountId`, Apple
  /// `appAccountToken`.
  Future<bool> buy(
    StoreOffer offer, {
    required bool consumable,
    String? accountToken,
  });

  /// Asks the store for the purchases of its account; they arrive on
  /// [purchases] as `restored`. Shows no dialog (StoreKit 2:
  /// `Transaction.currentEntitlements`; Google: `queryPurchasesAsync`).
  Future<void> restore();

  /// Finishes the purchase in the store; consumes a consumable on Android.
  Future<void> complete(StorePurchase purchase, {required bool consumable});
}

/// [PurchaseStoreGateway] on `in_app_purchase`: Play Billing on Android,
/// StoreKit 2 on iOS and macOS.
class InAppPurchaseGateway implements PurchaseStoreGateway {
  InAppPurchaseGateway({InAppPurchase? plugin}) : _given = plugin;

  final InAppPurchase? _given;

  /// Touched only where there is a store: the plugin has no web part.
  InAppPurchase get _plugin => _given ?? InAppPurchase.instance;

  @override
  PurchaseStore? get store {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => PurchaseStore.playStore,
      TargetPlatform.iOS || TargetPlatform.macOS => PurchaseStore.appStore,
      _ => null,
    };
  }

  bool get _android => store == PurchaseStore.playStore;

  @override
  Future<bool> isAvailable() async {
    if (store == null) return false;
    try {
      return await _plugin.isAvailable();
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<List<StorePurchase>> get purchases => store == null
      ? const Stream.empty()
      : _plugin.purchaseStream.map(
          (list) => [for (final p in list) _convert(p)],
        );

  StorePurchase _convert(PurchaseDetails p) => StorePurchase(
    productId: p.productID,
    // Google: the purchase token; StoreKit 2: the transaction id.
    storeRef: _android
        ? p.verificationData.serverVerificationData
        : (p.purchaseID ?? ''),
    status: switch (p.status) {
      PurchaseStatus.pending => StorePurchaseStatus.pending,
      PurchaseStatus.purchased => StorePurchaseStatus.purchased,
      PurchaseStatus.restored => StorePurchaseStatus.restored,
      PurchaseStatus.error => StorePurchaseStatus.error,
      PurchaseStatus.canceled => StorePurchaseStatus.canceled,
    },
    needsCompletion: p.pendingCompletePurchase,
    transactionDate: _date(p.transactionDate),
    error: p.error?.message,
    handle: p,
  );

  static DateTime? _date(String? millis) {
    final value = millis == null ? null : int.tryParse(millis);
    return value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }

  @override
  Future<List<StoreOffer>> query(Set<String> productIds) async {
    if (productIds.isEmpty) return const [];
    final response = await _plugin.queryProductDetails(productIds);
    return [for (final d in response.productDetails) _offer(d)];
  }

  StoreOffer _offer(ProductDetails d) {
    String? basePlan;
    String? offer;
    if (d is GooglePlayProductDetails) {
      final index = d.subscriptionIndex;
      final offers = d.productDetails.subscriptionOfferDetails;
      if (index != null && offers != null && index < offers.length) {
        basePlan = offers[index].basePlanId;
        offer = offers[index].offerId;
      }
    }
    return StoreOffer(
      productId: d.id,
      basePlanId: basePlan,
      offerId: offer,
      title: d.title,
      description: d.description,
      price: d.price,
      rawPrice: d.rawPrice,
      currencyCode: d.currencyCode,
      handle: d,
    );
  }

  @override
  Future<bool> buy(
    StoreOffer offer, {
    required bool consumable,
    String? accountToken,
  }) {
    final details = offer.handle;
    if (details is! ProductDetails) return Future.value(false);
    final param = PurchaseParam(
      productDetails: details,
      applicationUserName: accountToken,
    );
    // Consumed only after Lotse confirmed the purchase, in [complete].
    return consumable
        ? _plugin.buyConsumable(purchaseParam: param, autoConsume: false)
        : _plugin.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> restore() => _plugin.restorePurchases();

  @override
  Future<void> complete(
    StorePurchase purchase, {
    required bool consumable,
  }) async {
    final details = purchase.handle;
    if (details is! PurchaseDetails) return;
    if (consumable && _android) {
      final addition = _plugin
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      await addition.consumePurchase(details);
      return;
    }
    if (details.pendingCompletePurchase) {
      await _plugin.completePurchase(details);
    }
  }
}
