import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:lotse/lotse_internal.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'models.dart';
import 'server.dart';
import 'storage.dart';
import 'store.dart';

/// How long entitlements from the server count as fresh before the next
/// start or resume asks again (docs/PURCHASES.md, "SDK", Cache).
const lotseEntitlementsMaxAge = Duration(minutes: 5);

/// How long a fresh purchase Lotse could not check yet gives access on the
/// store's word.
const lotseProvisionalAccess = Duration(hours: 24);

/// How often the silent check of the store account at start runs at most,
/// unless a report is still open. Every reported purchase costs one of the
/// 30 reports a device may make a day.
const lotseStartSyncInterval = Duration(hours: 24);

/// Waits between retries of open reports.
const lotseRetryDelays = [
  Duration(seconds: 30),
  Duration(minutes: 2),
  Duration(minutes: 10),
  Duration(minutes: 30),
];

/// In-app purchases and subscriptions on Lotse (docs/PURCHASES.md, "SDK").
///
/// ```dart
/// await Lotse.init(publicKey: '…', serverUrl: '…');
/// await LotsePurchases.init();
/// final products = await LotsePurchases.instance.products();
/// final result = await LotsePurchases.instance.buy(products.first);
/// if (LotsePurchases.instance.hasEntitlement('pro')) { … }
/// ```
///
/// A purchase goes from the store dialog to Lotse, which reads it from the
/// store, and only after Lotse answered is it finished in the store; a
/// purchase that could not be reported stays open there and in a queue on
/// the device, and is reported again later. Failures are logged, never
/// thrown into the app.
class LotsePurchases {
  LotsePurchases._({
    required this._store,
    required this._server,
    required this._storage,
    required this._installId,
    required this._customerChanged,
    required this._now,
    required this._packageName,
    required this._watchLifecycle,
    this._restoreWait = const Duration(seconds: 3),
  });

  /// Purchases over test doubles; [start] is up to the test.
  @visibleForTesting
  factory LotsePurchases.forTesting({
    required PurchaseStoreGateway store,
    required PurchaseServer server,
    PurchaseStorage? storage,
    String? Function()? installId,
    Stream<void>? customerChanged,
    DateTime Function()? now,
    String? packageName = 'dev.lotse.test',
    Duration restoreWait = const Duration(milliseconds: 10),
  }) => LotsePurchases._(
    store: store,
    server: server,
    storage: storage ?? MemoryPurchaseStorage(),
    installId: installId ?? () => 'install-1',
    customerChanged: customerChanged ?? const Stream.empty(),
    now: now ?? () => DateTime.now().toUtc(),
    packageName: () async => packageName,
    watchLifecycle: false,
    restoreWait: restoreWait,
  );

  static LotsePurchases? _instance;
  static Future<LotsePurchases>? _initialization;

  /// The purchases after [init]. Throws before.
  static LotsePurchases get instance =>
      _instance ??
      (throw StateError(
        'Call LotsePurchases.init() after Lotse.init() before use.',
      ));

  /// Starts the purchases: loads the cached entitlements and listens to the
  /// store, then, without holding up the app, reports what is still open,
  /// asks Lotse and checks the store account silently. Call once after
  /// `Lotse.init`; later calls return the same instance. Never throws for
  /// store or network problems.
  static Future<LotsePurchases> init() => _initialization ??= () async {
    await LotseInternal.ready;
    final purchases = LotsePurchases._(
      store: InAppPurchaseGateway(),
      server: const LotsePurchaseServer(),
      storage: const SecurePurchaseStorage(),
      installId: () => LotseInternal.installId,
      customerChanged: LotseInternal.customerChanged,
      now: () => DateTime.now().toUtc(),
      packageName: () async {
        try {
          return (await PackageInfo.fromPlatform()).packageName;
        } catch (_) {
          return null;
        }
      },
      watchLifecycle: true,
    );
    _instance = purchases;
    await purchases.start();
    return purchases;
  }();

  final PurchaseStoreGateway _store;
  final PurchaseServer _server;
  final PurchaseStorage _storage;
  final String? Function() _installId;
  final Stream<void> _customerChanged;
  final DateTime Function() _now;
  final Future<String?> Function() _packageName;
  final bool _watchLifecycle;
  final Duration _restoreWait;

  final _changes = StreamController<LotseEntitlements>.broadcast();
  var _confirmed = LotseEntitlements.empty;
  DateTime? _checkedAt;
  final List<_OpenReport> _open = [];
  var _current = LotseEntitlements.empty;

  /// Products from the last [products] call, by store product id.
  final Map<String, LotseProduct> _products = {};
  final Map<String, Future<LotsePurchaseResult?>> _inFlight = {};
  final Map<String, StorePurchase> _handles = {};

  /// Store refs Lotse confirmed in this run, with whether they are
  /// consumables: when the store hands one over again unfinished, it is
  /// finished without a second report.
  final Map<String, bool> _confirmedRefs = {};
  final Map<String, Completer<LotsePurchaseResult>> _buying = {};
  final List<Completer<void>> _batchWaiters = [];
  String? _customerToken;
  String? _cacheInstall;
  String? _package;
  Timer? _retryTimer;
  var _retryStep = 0;
  var _started = false;

  // MARK: Public API

  /// The entitlements now, also when offline: confirmed by Lotse, plus those
  /// of fresh purchases Lotse could not check yet (24 hours).
  LotseEntitlements get current => _current;

  /// Emits whenever the entitlements change.
  Stream<LotseEntitlements> get entitlements => _changes.stream;

  /// Whether the customer has the entitlement [key] now. Synchronous, from
  /// the cache: what Lotse confirmed last, until it expires.
  bool hasEntitlement(String key) => _current.activeAt(_now()).contains(key);

  /// Where the user manages their subscription in the store; null where the
  /// app has no store.
  String? get managementUrl => switch (_store.store) {
    PurchaseStore.playStore =>
      _package == null
          ? 'https://play.google.com/store/account/subscriptions'
          : 'https://play.google.com/store/account/subscriptions?package=$_package',
    PurchaseStore.appStore => 'https://apps.apple.com/account/subscriptions',
    _ => null,
  };

  /// The products of the console that the store offers on this device, with
  /// the store's price and title. A product the store does not know is left
  /// out. Empty without a store or on any failure.
  Future<List<LotseProduct>> products() async {
    try {
      if (!await _store.isAvailable()) return const [];
      final configured = await _server.products();
      if (configured.isEmpty) return const [];
      final offers = await _store.query({
        for (final p in configured) p.storeProductId,
      });
      final result = <LotseProduct>[];
      for (final p in configured) {
        final offer = _pickOffer(p, offers);
        if (offer == null) continue;
        final product = LotseProduct(
          id: p.storeProductId,
          basePlanId: p.basePlanId.isEmpty ? null : p.basePlanId,
          kind: switch (p.kind) {
            StoreProductKind.subscription => LotseProductKind.subscription,
            StoreProductKind.nonConsumable => LotseProductKind.nonConsumable,
            StoreProductKind.consumable => LotseProductKind.consumable,
          },
          displayName: p.displayName,
          title: offer.title,
          description: offer.description,
          price: offer.price,
          rawPrice: offer.rawPrice,
          currencyCode: offer.currencyCode,
          period: p.period,
          entitlements: Set.unmodifiable(p.entitlements),
          handle: offer,
        );
        result.add(product);
        _products[product.id] = product;
      }
      return result;
    } catch (error) {
      _log('could not load the products', error);
      return const [];
    }
  }

  /// Opens the store dialog for [product] and waits for the outcome. On
  /// success Lotse has checked the purchase, or could not and grants it
  /// provisionally ([LotsePurchaseSuccess.provisional]).
  Future<LotsePurchaseResult> buy(LotseProduct product) async {
    final offer = product.handle;
    if (offer is! StoreOffer || !await _store.isAvailable()) {
      return const LotsePurchaseFailed(LotsePurchaseFailure.storeUnavailable);
    }
    if (_buying.containsKey(product.id)) {
      return _buying[product.id]!.future;
    }
    final waiter = Completer<LotsePurchaseResult>();
    _buying[product.id] = waiter;
    try {
      final started = await _store.buy(
        offer,
        consumable: product.kind == LotseProductKind.consumable,
        accountToken: await _token(),
      );
      if (!started) {
        _buying.remove(product.id);
        return const LotsePurchaseFailed(LotsePurchaseFailure.storeError);
      }
    } catch (error) {
      _buying.remove(product.id);
      _log('the store dialog failed', error);
      return LotsePurchaseFailed(
        LotsePurchaseFailure.storeError,
        error.runtimeType.toString(),
      );
    }
    return waiter.future;
  }

  /// Asks the store for the purchases of its account, reports them to Lotse
  /// and returns the entitlements afterwards. For a "Restore purchases"
  /// button; shows no store dialog. With the project setting "transfer" a
  /// purchase moves to this customer (docs/PURCHASES.md, "Wer besitzt einen
  /// Kauf").
  Future<LotseEntitlements> restore() async {
    try {
      if (await _store.isAvailable()) await _restoreFromStore();
      await refresh(force: true);
    } catch (error) {
      _log('could not restore the purchases', error);
    }
    return _current;
  }

  /// Asks Lotse for the entitlements unless the last answer is younger than
  /// [lotseEntitlementsMaxAge]; with [force] always. Keeps the cache when
  /// Lotse cannot be reached.
  Future<void> refresh({bool force = false}) async {
    final checked = _checkedAt;
    if (!force &&
        checked != null &&
        _now().difference(checked) < lotseEntitlementsMaxAge) {
      return;
    }
    try {
      _applyServer(await _server.entitlements());
    } catch (error) {
      _log('could not refresh the entitlements', error);
    }
  }

  // MARK: Start

  /// Starts listening; called by [init]. With [waitForNetwork] the returned
  /// future also waits for the open reports, Lotse and the store account.
  /// Public for tests.
  @visibleForTesting
  Future<void> start({bool waitForNetwork = true}) async {
    if (_started) return;
    _started = true;
    _package = await _packageName();
    await _loadCache();
    await _loadOpen();
    _publish();
    _store.purchases.listen(
      (batch) => unawaited(_onPurchases(batch)),
      onError: (Object error) => _log('the purchase stream failed', error),
    );
    _customerChanged.listen((_) => unawaited(_onCustomerChanged()));
    if (_watchLifecycle) {
      AppLifecycleListener(onResume: () => unawaited(_onResume()));
    }
    // Open reports from an earlier run: their store purchases still wait to
    // be finished, so the store account is checked in any case.
    final hadOpen = _open.isNotEmpty;
    final network = () async {
      await _retryOpen();
      await refresh();
      await _startSync(force: hadOpen);
    }();
    if (waitForNetwork) await network;
  }

  Future<void> _onResume() async {
    await _retryOpen();
    await refresh();
  }

  Future<void> _onCustomerChanged() async {
    _customerToken = null;
    await _loadCache();
    _publish();
    await refresh(force: true);
  }

  /// The silent check of the store account (docs/PURCHASES.md, "SDK", "Beim
  /// Start"): at most every [lotseStartSyncInterval], or when a report is
  /// still open.
  Future<void> _startSync({bool force = false}) async {
    try {
      if (!await _store.isAvailable()) return;
      final last = DateTime.tryParse(await _storage.read(_syncKey) ?? '');
      final due =
          force ||
          last == null ||
          _now().difference(last) >= lotseStartSyncInterval ||
          _open.isNotEmpty;
      if (!due) return;
      await _storage.write(_syncKey, _now().toIso8601String());
      await _restoreFromStore();
    } catch (error) {
      _log('could not check the store account', error);
    }
  }

  /// Restores from the store and waits for the batch it sends and for its
  /// reports. The plugins send restored purchases as one batch.
  Future<void> _restoreFromStore() async {
    final batch = Completer<void>();
    _batchWaiters.add(batch);
    await _store.restore();
    await batch.future.timeout(_restoreWait, onTimeout: () {});
    _batchWaiters.remove(batch);
    await Future.wait(_inFlight.values.toList());
  }

  // MARK: Store updates

  Future<void> _onPurchases(List<StorePurchase> batch) async {
    final reports = <Future<void>>[];
    for (final purchase in batch) {
      reports.add(_onPurchase(purchase));
    }
    for (final waiter in List.of(_batchWaiters)) {
      if (!waiter.isCompleted) waiter.complete();
    }
    await Future.wait(reports);
  }

  Future<void> _onPurchase(StorePurchase purchase) async {
    final product = purchase.productId;
    switch (purchase.status) {
      case StorePurchaseStatus.pending:
        _resolve(product, const LotsePurchasePending());
      case StorePurchaseStatus.canceled:
        await _completeQuietly(purchase);
        _resolve(product, const LotsePurchaseCancelled());
      case StorePurchaseStatus.error:
        await _completeQuietly(purchase);
        _resolve(
          product,
          LotsePurchaseFailed(LotsePurchaseFailure.storeError, purchase.error),
        );
      case StorePurchaseStatus.purchased:
      case StorePurchaseStatus.restored:
        if (purchase.storeRef.isEmpty) {
          _resolve(
            product,
            const LotsePurchaseFailed(
              LotsePurchaseFailure.storeError,
              'The store gave no reference for the purchase.',
            ),
          );
          return;
        }
        final confirmed = _confirmedRefs[purchase.storeRef];
        if (confirmed != null &&
            purchase.status == StorePurchaseStatus.restored) {
          if (purchase.needsCompletion) await _finish(purchase, confirmed);
          return;
        }
        if (purchase.needsCompletion) _handles[purchase.storeRef] = purchase;
        final result = await _report(
          storeRef: purchase.storeRef,
          productId: product,
          fresh: purchase.status == StorePurchaseStatus.purchased,
          at: purchase.transactionDate,
        );
        if (purchase.status == StorePurchaseStatus.purchased &&
            result != null) {
          _resolve(product, result);
        }
    }
  }

  void _resolve(String productId, LotsePurchaseResult result) {
    final waiter = _buying.remove(productId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(result);
  }

  Future<void> _completeQuietly(StorePurchase purchase) async {
    if (!purchase.needsCompletion) return;
    try {
      await _store.complete(purchase, consumable: false);
    } catch (error) {
      _log('could not finish a purchase in the store', error);
    }
  }

  // MARK: Reports

  /// Reports one purchase, once at a time per [storeRef]. Puts it into the
  /// open reports first, so a crash or a missing network loses nothing.
  Future<LotsePurchaseResult?> _report({
    required String storeRef,
    required String productId,
    required bool fresh,
    DateTime? at,
  }) => _inFlight[storeRef] ??= () async {
    try {
      final existing = _open.where((o) => o.storeRef == storeRef).firstOrNull;
      final known = _products[productId];
      final open =
          existing ??
          _OpenReport(
            storeRef: storeRef,
            productId: productId,
            entitlements: known?.entitlements.toList() ?? const [],
            consumable: known?.kind == LotseProductKind.consumable,
            provisionalUntil: fresh
                ? (at ?? _now()).add(lotseProvisionalAccess)
                : null,
          );
      if (existing == null) {
        _open.add(open);
        await _saveOpen();
        _publish();
      }
      return await _send(open);
    } finally {
      unawaited(Future(() => _inFlight.remove(storeRef)));
    }
  }();

  Future<LotsePurchaseResult?> _send(_OpenReport open) async {
    final store = _store.store;
    if (store == null) return null;
    try {
      final answer = await _server.report(
        PurchaseReport(
          store: store,
          storeProductId: open.productId,
          storeRef: open.storeRef,
        ),
      );
      await _close(open, finish: true);
      _applyServer(answer);
      _retryStep = 0;
      return LotsePurchaseSuccess(_current);
    } on LotseConflictException {
      // Valid, but another customer of the app owns it and the project keeps
      // it there. Finished in the store: it is no error of the store.
      await _close(open, finish: true);
      return const LotsePurchaseFailed(
        LotsePurchaseFailure.rejected,
        'The purchase belongs to another customer of the app.',
      );
    } on LotsePurchaseCheckException catch (error) {
      if (error.retry) return _keepOpen(open);
      await _close(open, finish: false);
      return LotsePurchaseFailed(LotsePurchaseFailure.rejected, error.message);
    } on LotseInvalidInputException catch (error) {
      await _close(open, finish: false);
      return LotsePurchaseFailed(LotsePurchaseFailure.rejected, error.message);
    } catch (error) {
      // No network, Lotse down, the identity replaced meanwhile.
      _log('could not report a purchase, keeping it', error);
      return _keepOpen(open);
    }
  }

  LotsePurchaseResult _keepOpen(_OpenReport open) {
    _scheduleRetry();
    return LotsePurchaseSuccess(
      _current,
      provisional: open.provisionalUntil != null,
    );
  }

  /// Takes [open] off the queue; with [finish] finishes the purchase in the
  /// store, which Lotse has seen now. Without, the store keeps it open: a
  /// Google purchase is refunded after three days, a StoreKit transaction
  /// comes back at the next start.
  Future<void> _close(_OpenReport open, {required bool finish}) async {
    _open.removeWhere((o) => o.storeRef == open.storeRef);
    await _saveOpen();
    final handle = _handles.remove(open.storeRef);
    if (finish) {
      _confirmedRefs[open.storeRef] = open.consumable;
      if (handle != null) await _finish(handle, open.consumable);
    }
    _publish();
  }

  Future<void> _finish(StorePurchase purchase, bool consumable) async {
    try {
      await _store.complete(purchase, consumable: consumable);
    } catch (error) {
      _log('could not finish a purchase in the store', error);
    }
  }

  Future<void> _retryOpen() async {
    for (final open in List.of(_open)) {
      await _report(
        storeRef: open.storeRef,
        productId: open.productId,
        fresh: false,
      );
    }
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    final delay =
        lotseRetryDelays[min(_retryStep, lotseRetryDelays.length - 1)];
    _retryStep++;
    _retryTimer = Timer(delay, () => unawaited(_retryOpen()));
  }

  Future<String?> _token() async {
    if (_customerToken != null) return _customerToken;
    try {
      return _customerToken = await _server.customerToken();
    } catch (error) {
      // Without it Lotse still checks the purchase; only a renewal whose
      // first report got lost cannot be matched by the token.
      _log('no customer token for the store', error);
      return null;
    }
  }

  // MARK: Entitlements and cache

  void _applyServer(CustomerEntitlements answer) {
    _confirmed = LotseEntitlements([
      for (final e in answer.entitlements)
        LotseEntitlement(
          key: e.key,
          expiresAt: e.expiresAt?.toUtc(),
          willRenew: e.willRenew,
          granted: e.granted,
        ),
    ]);
    _checkedAt = answer.checkedAt.toUtc();
    unawaited(_saveCache());
    _publish();
  }

  void _publish() {
    final now = _now();
    final next = LotseEntitlements([
      ..._confirmed.all,
      for (final open in _open)
        if (open.provisionalUntil != null &&
            open.provisionalUntil!.isAfter(now))
          for (final key in open.entitlements)
            LotseEntitlement(
              key: key,
              expiresAt: open.provisionalUntil,
              provisional: true,
            ),
    ]);
    if (next == _current) return;
    _current = next;
    _changes.add(next);
  }

  String get _syncKey => 'lotse_purchases.v1.start_sync';
  String get _openKey => 'lotse_purchases.v1.open';
  String _cacheKey(String install) =>
      'lotse_purchases.v1.entitlements.$install';

  /// The cache belongs to the install: after `Lotse.reset` another customer
  /// starts with nothing.
  Future<void> _loadCache() async {
    final install = _installId();
    _cacheInstall = install;
    _confirmed = LotseEntitlements.empty;
    _checkedAt = null;
    if (install == null) return;
    try {
      final raw = await _storage.read(_cacheKey(install));
      if (raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map) return;
      _checkedAt = DateTime.tryParse('${json['checkedAt']}')?.toUtc();
      final list = json['entitlements'];
      _confirmed = LotseEntitlements([
        if (list is List)
          for (final item in list) ?LotseEntitlement.fromJson(item),
      ]);
    } catch (error) {
      _log('could not read the cached entitlements', error);
    }
  }

  Future<void> _saveCache() async {
    final install = _cacheInstall ?? _installId();
    if (install == null) return;
    try {
      await _storage.write(
        _cacheKey(install),
        jsonEncode({
          'checkedAt': _checkedAt?.toIso8601String(),
          'entitlements': [for (final e in _confirmed.all) e.toJson()],
        }),
      );
    } catch (error) {
      _log('could not cache the entitlements', error);
    }
  }

  Future<void> _loadOpen() async {
    try {
      final raw = await _storage.read(_openKey);
      if (raw == null) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      _open
        ..clear()
        ..addAll([for (final item in list) ?_OpenReport.fromJson(item)]);
    } catch (error) {
      _log('could not read the open reports', error);
    }
  }

  Future<void> _saveOpen() async {
    try {
      await _storage.write(
        _openKey,
        jsonEncode([for (final o in _open) o.toJson()]),
      );
    } catch (error) {
      _log('could not store the open reports', error);
    }
  }

  static StoreOffer? _pickOffer(
    PurchaseProduct product,
    List<StoreOffer> offers,
  ) {
    final matching = [
      for (final o in offers)
        if (o.productId == product.storeProductId &&
            (product.basePlanId.isEmpty || o.basePlanId == product.basePlanId))
          o,
    ];
    if (matching.isEmpty) return null;
    // Google lists the offers the user may take (a free trial) next to the
    // base plan; one with an offer id gets the user that offer.
    return matching.where((o) => o.offerId != null).firstOrNull ??
        matching.first;
  }

  static void _log(String what, Object error) =>
      debugPrint('LotsePurchases: $what: ${error.runtimeType}');

  /// Ends the instance. Tests only.
  @visibleForTesting
  Future<void> dispose() async {
    _retryTimer?.cancel();
    await _changes.close();
    if (identical(_instance, this)) {
      _instance = null;
      _initialization = null;
    }
  }
}

/// A purchase that went to the store but not yet through Lotse.
class _OpenReport {
  _OpenReport({
    required this.storeRef,
    required this.productId,
    required this.entitlements,
    required this.consumable,
    this.provisionalUntil,
  });

  final String storeRef;
  final String productId;

  /// What the product unlocks, for the provisional access.
  final List<String> entitlements;
  final bool consumable;

  /// Set for a fresh purchase: access on the store's word until then.
  final DateTime? provisionalUntil;

  Map<String, Object?> toJson() => {
    'storeRef': storeRef,
    'productId': productId,
    'entitlements': entitlements,
    'consumable': consumable,
    'provisionalUntil': provisionalUntil?.toIso8601String(),
  };

  static _OpenReport? fromJson(Object? json) {
    if (json is! Map) return null;
    final ref = json['storeRef'];
    final product = json['productId'];
    if (ref is! String || product is! String) return null;
    final keys = json['entitlements'];
    final until = json['provisionalUntil'];
    return _OpenReport(
      storeRef: ref,
      productId: product,
      entitlements: [
        if (keys is List)
          for (final k in keys)
            if (k is String) k,
      ],
      consumable: json['consumable'] == true,
      provisionalUntil: until is String
          ? DateTime.tryParse(until)?.toUtc()
          : null,
    );
  }
}
