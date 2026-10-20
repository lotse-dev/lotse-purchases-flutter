import 'package:lotse/lotse_internal.dart';

/// The Lotse calls the purchases make, behind one seam so tests run without
/// a server.
abstract interface class PurchaseServer {
  Future<List<PurchaseProduct>> products();
  Future<CustomerEntitlements> report(PurchaseReport report);
  Future<CustomerEntitlements> entitlements();
  Future<String> customerToken();
}

/// [PurchaseServer] over the SDK's identity: every call carries the install
/// credential of the current identity.
class LotsePurchaseServer implements PurchaseServer {
  const LotsePurchaseServer();

  @override
  Future<List<PurchaseProduct>> products() => LotseInternal.runPrivate(
    (client, installId, credential) =>
        client.sdk.purchaseProducts(installId, credential),
  );

  @override
  Future<CustomerEntitlements> report(PurchaseReport report) =>
      LotseInternal.runPrivate(
        (client, installId, credential) =>
            client.sdk.reportPurchase(installId, credential, report),
      );

  @override
  Future<CustomerEntitlements> entitlements() => LotseInternal.runPrivate(
    (client, installId, credential) =>
        client.sdk.purchaseEntitlements(installId, credential),
  );

  @override
  Future<String> customerToken() => LotseInternal.runPrivate(
    (client, installId, credential) =>
        client.sdk.purchaseCustomerToken(installId, credential),
  );
}
