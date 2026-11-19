import 'dart:convert';

import 'package:pinenacl/ed25519.dart';

/// Result of checking the detached signature of the community catalog.
enum CatalogSignature {
  /// `recipes.json.sig` is a valid Ed25519 signature by [RecipeSignature.publicKeyBase64].
  verified,

  /// No signature was published (linxr-marketplace does not sign yet).
  unsigned,

  /// A signature exists but does not match: tampered catalog or wrong key.
  invalid,
}

/// Verifies `recipes.json` from AI2TH/linxr-marketplace against a detached
/// Ed25519 signature (`recipes.json.sig`: the 64-byte raw signature over the
/// exact bytes of recipes.json, base64-encoded).
class RecipeSignature {
  RecipeSignature._();

  /// Raw 32-byte Ed25519 public key (base64) of the linxr-marketplace
  /// catalog signing key. The private key is held by the repository owner
  /// and never committed. Sign with, for example, Node:
  ///   crypto.sign(null, fs.readFileSync('recipes.json'), privateKey)
  /// and write the base64 result to recipes.json.sig.
  static const publicKeyBase64 = 'Lw8wi4EO3hGl8rPLgDedDc1KDu+hDL/g1vOLATG1jQ0=';

  static CatalogSignature verify(
    List<int> catalogBytes,
    String? signatureText, {
    String publicKey = publicKeyBase64,
  }) {
    final sigText = signatureText?.trim() ?? '';
    if (sigText.isEmpty) return CatalogSignature.unsigned;
    try {
      final sig = base64.decode(sigText);
      final key = base64.decode(publicKey);
      if (sig.length != Signature.signatureLength || key.length != VerifyKey.keyLength) {
        return CatalogSignature.invalid;
      }
      final ok = VerifyKey(Uint8List.fromList(key)).verify(
        signature: Signature(Uint8List.fromList(sig)),
        message: Uint8List.fromList(catalogBytes),
      );
      return ok ? CatalogSignature.verified : CatalogSignature.invalid;
    } catch (_) {
      return CatalogSignature.invalid;
    }
  }

  /// Whether a catalog with this signature state may be used.
  /// An invalid signature is always rejected; an unsigned catalog only when
  /// the user turned on "Require signed community recipes".
  static bool accept(CatalogSignature sig, {required bool requireSigned}) {
    switch (sig) {
      case CatalogSignature.verified:
        return true;
      case CatalogSignature.unsigned:
        return !requireSigned;
      case CatalogSignature.invalid:
        return false;
    }
  }
}
