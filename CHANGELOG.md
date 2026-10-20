## 0.1.0

First version.

* `LotsePurchases.init()` after `Lotse.init`, then `LotsePurchases.instance`.
* `products()`: the products of the Lotse console for this app, with price and title from the store. Google subscriptions per base plan; an offer the user may take (a free trial) is preferred.
* `buy(product)`: the store dialog, the check by Lotse, and only then the purchase is finished in the store. Results `LotsePurchaseSuccess` (with `provisional` when Lotse could not be reached), `LotsePurchaseCancelled`, `LotsePurchasePending`, `LotsePurchaseFailed`.
* `hasEntitlement('pro')` synchronous from the cache, `entitlements` stream, `current`, `refresh()`.
* `restore()` without a store dialog (StoreKit 2 `Transaction.currentEntitlements`, Google `queryPurchasesAsync`); a silent check of the store account at start, at most once a day.
* Open reports survive restarts and are sent again; a fresh purchase counts for 24 hours on the store's word until Lotse confirms it.
* The customer's UUID goes to the store with every purchase: Google `obfuscatedAccountId`, Apple `appAccountToken`.
* `managementUrl` for the store's subscription page.
