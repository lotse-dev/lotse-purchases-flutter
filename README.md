# lotse_purchases

In-app purchases and subscriptions for Flutter apps on a [Lotse](https://lotse.dev)
backend. Your team sets up products and entitlements in the Lotse console; the app
asks `hasEntitlement('pro')`. Lotse checks every purchase with the store itself,
keeps renewals, cancellations, billing problems and refunds up to date from the
stores' notifications, and puts every change on the same event stream as your
analytics, segments, journeys and webhooks.

Google Play on Android, the App Store on iOS (StoreKit 2). Built on
`in_app_purchase`. Needs the [`lotse`](https://pub.dev/packages/lotse) SDK.

## Install

```bash
flutter pub add lotse lotse_purchases
```

## Set up

In the Lotse console, per app: connect the store (Google Play service account, App
Store In-App Purchase key), create the entitlements (`pro`) and the products with
their store ids, and say which product unlocks which entitlement.

```dart
await Lotse.init(publicKey: 'lt_pk_...', serverUrl: 'https://api.lotse.dev/');
await LotsePurchases.init();
```

`init` returns once the cached entitlements are loaded and the store is listened
to. Reporting open purchases, asking Lotse and the silent check of the store
account run behind it; nothing throws into the app.

## Sell

```dart
final purchases = LotsePurchases.instance;
final products = await purchases.products();      // from the console, priced by the store
final result = await purchases.buy(products.first);
switch (result) {
  case LotsePurchaseSuccess(:final provisional): // unlocked; provisional = not checked yet
  case LotsePurchaseCancelled():                 // the user closed the dialog
  case LotsePurchasePending():                   // waits for a payment or a parent
  case LotsePurchaseFailed(:final failure):      // store or Lotse said no
}
```

`products()` lists what the console has for this app and the store knows on this
device, with the store's price and title (`price`, `rawPrice`, `currencyCode`) and
the keys it unlocks (`entitlements`). For a Google subscription with a free trial
the trial offer is used when the user may take it.

## Check access

```dart
if (purchases.hasEntitlement('pro')) { … }         // synchronous, from the cache
purchases.entitlements.listen((e) => setState(() {}));
await purchases.restore();                          // "Restore purchases"
final url = purchases.managementUrl;               // the store's subscription page
```

What `hasEntitlement` answers:

- what Lotse confirmed last, until it expires. The SDK asks again after five
  minutes, at start and when the app comes back to the front. Offline, cached
  entitlements stay valid until their own end;
- a fresh purchase Lotse could not check yet (no network, Lotse down) counts for
  24 hours on the store's word, then only once Lotse confirms it. Such a purchase
  stays open in the store and in a queue on the device and is reported again.

## How a purchase goes

1. The store dialog, with the customer's random UUID (Google
   `obfuscatedAccountId`, Apple `appAccountToken`), so Lotse can match renewals.
2. The SDK reports the store's reference to Lotse; Lotse reads the purchase from
   the store and acknowledges it at Google.
3. Only after Lotse answered is the purchase finished in the store
   (`completePurchase`, a consumable consumed on Android). Finishing it earlier
   would lose it if the report never arrived.

At start, at most once a day (or when a report is still open), the SDK reports the
purchases of the store account silently, without a dialog. That catches purchases
made before the SDK was in the app and reports that got lost.

## Across devices: identity verification

Purchases belong to the user only on devices identified with a valid user hash
(`Lotse.instance.identify(userId, userHash: …)`, see the `lotse` README). An
unverified device sees only its own purchases: otherwise anyone could call
`identify('u_42')` and get the purchases of `u_42`. Restoring on another account
moves the purchase to the restoring customer unless the project keeps purchases
where they are (project setting).

## Platforms

Android (Play Billing) and iOS (StoreKit 2). macOS builds, but Lotse has no Mac
apps yet: `products()` is empty there. On the web and other platforms there is no
store; `products()` is empty and `buy` fails with `storeUnavailable`.
