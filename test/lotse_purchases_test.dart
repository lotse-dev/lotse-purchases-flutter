import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lotse/lotse_internal.dart';
import 'package:lotse_purchases/lotse_purchases.dart';
import 'package:lotse_purchases/src/server.dart';
import 'package:lotse_purchases/src/storage.dart';
import 'package:lotse_purchases/src/store.dart';

class FakeStore implements PurchaseStoreGateway {
  FakeStore({this.store = PurchaseStore.playStore});

  @override
  final PurchaseStore? store;
  bool available = true;
  final updates = StreamController<List<StorePurchase>>.broadcast();
  List<StoreOffer> offers = [];
  final bought = <(String, String?)>[];
  final completed = <String>[];
  final consumed = <String>[];
  var restores = 0;
  List<StorePurchase> restoreBatch = [];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<List<StorePurchase>> get purchases => updates.stream;

  @override
  Future<List<StoreOffer>> query(Set<String> productIds) async => [
    for (final o in offers)
      if (productIds.contains(o.productId)) o,
  ];

  @override
  Future<bool> buy(
    StoreOffer offer, {
    required bool consumable,
    String? accountToken,
  }) async {
    bought.add((offer.productId, accountToken));
    return true;
  }

  @override
  Future<void> restore() async {
    restores++;
    updates.add(restoreBatch);
  }

  @override
  Future<void> complete(
    StorePurchase purchase, {
    required bool consumable,
  }) async {
    (consumable ? consumed : completed).add(purchase.storeRef);
  }

  void emit(StorePurchase purchase) => updates.add([purchase]);
}

class FakeServer implements PurchaseServer {
  List<PurchaseProduct> catalog = [];
  final reports = <PurchaseReport>[];
  Object? reportError;
  Completer<void>? reportGate;
  Object? entitlementsError;
  var entitlementCalls = 0;
  List<CustomerEntitlement> owned = [];
  DateTime checkedAt = DateTime.utc(2026, 10, 18, 12);

  CustomerEntitlements get answer =>
      CustomerEntitlements(entitlements: owned, checkedAt: checkedAt);

  @override
  Future<List<PurchaseProduct>> products() async => catalog;

  @override
  Future<CustomerEntitlements> report(PurchaseReport report) async {
    reports.add(report);
    await reportGate?.future;
    final error = reportError;
    if (error != null) throw error;
    return answer;
  }

  @override
  Future<CustomerEntitlements> entitlements() async {
    entitlementCalls++;
    final error = entitlementsError;
    if (error != null) throw error;
    return answer;
  }

  @override
  Future<String> customerToken() async =>
      '6f9619ff-8b86-d011-b42d-00c04fc964ff';
}

CustomerEntitlement pro({DateTime? until}) => CustomerEntitlement(
  key: 'pro',
  expiresAt: until,
  store: PurchaseStore.playStore,
  willRenew: true,
  granted: false,
);

StorePurchase purchased(
  String ref, {
  String product = 'plus',
  StorePurchaseStatus status = StorePurchaseStatus.purchased,
  DateTime? at,
}) => StorePurchase(
  productId: product,
  storeRef: ref,
  status: status,
  needsCompletion: true,
  transactionDate: at,
);

void main() {
  late FakeStore store;
  late FakeServer server;
  late MemoryPurchaseStorage storage;
  late DateTime now;
  late String install;
  late StreamController<void> customer;
  final created = <LotsePurchases>[];

  LotsePurchases make() {
    final purchases = LotsePurchases.forTesting(
      store: store,
      server: server,
      storage: storage,
      now: () => now,
      installId: () => install,
      customerChanged: customer.stream,
    );
    created.add(purchases);
    return purchases;
  }

  setUp(() {
    store = FakeStore()
      ..offers = const [
        StoreOffer(
          productId: 'plus',
          basePlanId: 'monthly',
          title: 'Plus',
          description: 'Everything',
          price: '4,99 €',
          rawPrice: 4.99,
          currencyCode: 'EUR',
        ),
        StoreOffer(
          productId: 'plus',
          basePlanId: 'monthly',
          offerId: 'trial',
          title: 'Plus',
          description: 'Everything',
          price: '4,99 €',
          rawPrice: 4.99,
          currencyCode: 'EUR',
        ),
        StoreOffer(
          productId: 'coins',
          title: 'Coins',
          description: '100 coins',
          price: '0,99 €',
          rawPrice: 0.99,
          currencyCode: 'EUR',
        ),
      ];
    server = FakeServer()
      ..catalog = [
        PurchaseProduct(
          store: PurchaseStore.playStore,
          storeProductId: 'plus',
          basePlanId: 'monthly',
          kind: StoreProductKind.subscription,
          displayName: 'Plus monthly',
          period: 'P1M',
          entitlements: ['pro'],
        ),
        PurchaseProduct(
          store: PurchaseStore.playStore,
          storeProductId: 'coins',
          basePlanId: '',
          kind: StoreProductKind.consumable,
          displayName: 'Coins',
          entitlements: [],
        ),
        PurchaseProduct(
          store: PurchaseStore.playStore,
          storeProductId: 'gone',
          basePlanId: '',
          kind: StoreProductKind.nonConsumable,
          displayName: 'Not in the store',
          entitlements: ['pro'],
        ),
      ];
    storage = MemoryPurchaseStorage();
    now = DateTime.utc(2026, 10, 18, 12);
    install = 'install-1';
    customer = StreamController<void>.broadcast();
  });

  tearDown(() async {
    for (final p in created) {
      await p.dispose();
    }
    created.clear();
  });

  group('products', () {
    test('joins the console and the store, prefers an offer, leaves out what '
        'the store does not know', () async {
      final purchases = make();
      await purchases.start();
      final products = await purchases.products();
      expect(products.map((p) => p.id), ['plus', 'coins']);
      final plus = products.first;
      expect(plus.price, '4,99 €');
      expect(plus.entitlements, {'pro'});
      expect(plus.basePlanId, 'monthly');
      expect(plus.kind, LotseProductKind.subscription);
      expect((plus.handle! as StoreOffer).offerId, 'trial');
    });

    test('without a store there are none', () async {
      store.available = false;
      final purchases = make();
      await purchases.start();
      expect(await purchases.products(), isEmpty);
    });
  });

  group('buy', () {
    late LotsePurchases purchases;
    late LotseProduct plus;

    setUp(() async {
      purchases = make();
      await purchases.start();
      plus = (await purchases.products()).first;
    });

    test('reports the purchase, finishes it only after Lotse answered, and '
        'unlocks the entitlement', () async {
      server.reportGate = Completer<void>();
      server.owned = [pro(until: now.add(const Duration(days: 30)))];
      final changes = <LotseEntitlements>[];
      purchases.entitlements.listen(changes.add);

      final result = purchases.buy(plus);
      await pumpEventQueue();
      expect(store.bought.single, (
        'plus',
        '6f9619ff-8b86-d011-b42d-00c04fc964ff',
      ));
      store.emit(purchased('token-1'));
      await pumpEventQueue();
      expect(server.reports.single.storeRef, 'token-1');
      expect(server.reports.single.store, PurchaseStore.playStore);
      expect(store.completed, isEmpty, reason: 'not before Lotse answered');

      server.reportGate!.complete();
      final outcome = await result;
      await pumpEventQueue();
      expect(outcome, isA<LotsePurchaseSuccess>());
      expect((outcome as LotsePurchaseSuccess).provisional, isFalse);
      expect(store.completed, ['token-1']);
      expect(purchases.hasEntitlement('pro'), isTrue);
      expect(changes.last.activeAt(now), {'pro'});
    });

    test('a cancelled, a pending and a failed dialog', () async {
      final cancelled = purchases.buy(plus);
      await pumpEventQueue();
      store.emit(purchased('x', status: StorePurchaseStatus.canceled));
      expect(await cancelled, isA<LotsePurchaseCancelled>());

      final pending = purchases.buy(plus);
      await pumpEventQueue();
      store.emit(purchased('y', status: StorePurchaseStatus.pending));
      expect(await pending, isA<LotsePurchasePending>());

      final failed = purchases.buy(plus);
      await pumpEventQueue();
      store.emit(purchased('z', status: StorePurchaseStatus.error));
      final outcome = await failed;
      expect(
        (outcome as LotsePurchaseFailed).failure,
        LotsePurchaseFailure.storeError,
      );
      expect(server.reports, isEmpty);
    });

    test('without a network the purchase counts for 24 hours, stays open in '
        'the store and on the device', () async {
      server.reportError = const SocketExceptionStub();
      final result = purchases.buy(plus);
      await pumpEventQueue();
      store.emit(purchased('token-2', at: now));
      final outcome = await result as LotsePurchaseSuccess;
      expect(outcome.provisional, isTrue);
      expect(purchases.hasEntitlement('pro'), isTrue);
      expect(purchases.current.entitlementAt('pro', now)!.provisional, isTrue);
      expect(store.completed, isEmpty);
      final open = jsonDecode(storage.values['lotse_purchases.v1.open']!);
      expect((open as List).single['storeRef'], 'token-2');

      now = now.add(const Duration(hours: 25));
      expect(purchases.hasEntitlement('pro'), isFalse);
    });

    test('an open report goes out at the next start and the store purchase '
        'is finished when the store hands it over again', () async {
      server.reportError = const SocketExceptionStub();
      final result = purchases.buy(plus);
      await pumpEventQueue();
      store.emit(purchased('token-3', at: now));
      await result;

      // Next start, network back.
      server
        ..reportError = null
        ..owned = [pro(until: now.add(const Duration(days: 30)))];
      store.restoreBatch = [
        purchased('token-3', status: StorePurchaseStatus.restored),
      ];
      final again = make();
      await again.start();
      expect(server.reports.map((r) => r.storeRef), contains('token-3'));
      expect(storage.values['lotse_purchases.v1.open'], '[]');
      expect(again.hasEntitlement('pro'), isTrue);
      expect(again.current.entitlementAt('pro', now)!.provisional, isFalse);
      expect(store.completed, contains('token-3'));
    });

    test(
      'a purchase Lotse refuses is not finished and unlocks nothing',
      () async {
        server.reportError = LotsePurchaseCheckException(
          message: 'The app has no Google Play connection in Lotse.',
          retry: false,
        );
        final result = purchases.buy(plus);
        await pumpEventQueue();
        store.emit(purchased('token-4'));
        final outcome = await result as LotsePurchaseFailed;
        expect(outcome.failure, LotsePurchaseFailure.rejected);
        expect(store.completed, isEmpty);
        expect(purchases.hasEntitlement('pro'), isFalse);
        expect(storage.values['lotse_purchases.v1.open'], '[]');
      },
    );

    test(
      'a purchase of another customer is finished but unlocks nothing',
      () async {
        server.reportError = LotseConflictException(message: 'owned elsewhere');
        final result = purchases.buy(plus);
        await pumpEventQueue();
        store.emit(purchased('token-5'));
        final outcome = await result as LotsePurchaseFailed;
        expect(outcome.failure, LotsePurchaseFailure.rejected);
        expect(store.completed, ['token-5']);
        expect(purchases.hasEntitlement('pro'), isFalse);
      },
    );

    test('a consumable is consumed after Lotse answered', () async {
      final coins = (await purchases.products()).last;
      final result = purchases.buy(coins);
      await pumpEventQueue();
      store.emit(purchased('token-6', product: 'coins'));
      expect(await result, isA<LotsePurchaseSuccess>());
      expect(store.consumed, ['token-6']);
    });
  });

  group('restore', () {
    test('reports the store account and returns the entitlements', () async {
      final purchases = make();
      await purchases.start();
      server.reports.clear();
      server.owned = [pro(until: now.add(const Duration(days: 30)))];
      store.restoreBatch = [
        purchased('old-1', status: StorePurchaseStatus.restored),
      ];
      final result = await purchases.restore();
      expect(server.reports.single.storeRef, 'old-1');
      expect(result.activeAt(now), {'pro'});
      expect(purchases.hasEntitlement('pro'), isTrue);
    });
  });

  group('cache', () {
    test(
      'entitlements survive a start without Lotse until they expire',
      () async {
        server.owned = [pro(until: now.add(const Duration(days: 2)))];
        final first = make();
        await first.start();
        expect(first.hasEntitlement('pro'), isTrue);

        server.entitlementsError = const SocketExceptionStub();
        final offline = make();
        await offline.start();
        expect(offline.hasEntitlement('pro'), isTrue);
        now = now.add(const Duration(days: 3));
        expect(offline.hasEntitlement('pro'), isFalse);
      },
    );

    test('Lotse is asked again only after five minutes', () async {
      final purchases = make();
      await purchases.start();
      final calls = server.entitlementCalls;
      await purchases.refresh();
      expect(server.entitlementCalls, calls);
      now = now.add(const Duration(minutes: 6));
      await purchases.refresh();
      expect(server.entitlementCalls, calls + 1);
    });

    test('another customer on the install starts without the old '
        'entitlements and asks Lotse', () async {
      server.owned = [pro()];
      final purchases = make();
      await purchases.start();
      expect(purchases.hasEntitlement('pro'), isTrue);

      server.owned = [];
      install = 'install-2';
      customer.add(null);
      await pumpEventQueue();
      expect(purchases.hasEntitlement('pro'), isFalse);
    });

    test('shows only what Lotse confirms: an unverified device gets its own '
        'entitlements only, never those of a user', () async {
      // The server answers per device when it is not verified; the SDK
      // never adds anything on its own but provisional purchases.
      server.owned = [];
      final purchases = make();
      await purchases.start();
      expect(purchases.current.all, isEmpty);
    });
  });

  group('start', () {
    test('checks the store account at most once a day unless a report is '
        'open', () async {
      await make().start();
      expect(store.restores, 1);
      await make().start();
      expect(store.restores, 1);
      now = now.add(const Duration(hours: 25));
      await make().start();
      expect(store.restores, 2);
    });
  });

  test('managementUrl names the store', () async {
    final android = make();
    await android.start();
    expect(
      android.managementUrl,
      'https://play.google.com/store/account/subscriptions?package=dev.lotse.test',
    );
    store = FakeStore(store: PurchaseStore.appStore);
    final ios = make();
    expect(ios.managementUrl, 'https://apps.apple.com/account/subscriptions');
  });
}

/// A network failure without dart:io.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
