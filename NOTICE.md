# Source provenance

The initial Dart protocol implementation is adapted from the locally supplied
hongguo-web 1.1.1 package (Copyright (c) 2026 sunnysky123). Its root MIT text is
preserved at licenses/hongguo-web-MIT.txt.

The original source headers additionally attribute PureSign, AppSource and
WebSource to jackotom/hongguo-drama (GPL-3.0), with signing/spade algorithm ancestry
from woshishiq1/drpys via N3urda/hongguoTV. These upstream notices are preserved
here; the package-root MIT notice does not replace those component notices.
Spade's source describes its v1 implementation as derived from
libttmplayer.so FUN_001c4550.

Adapted components:
- packages/core/lib/src/crypto/pure_sign.dart — server/src/core/pure-sign.js
- packages/core/lib/src/crypto/spade.dart — server/src/core/spade.js
- packages/core/lib/src/crypto/media_url.dart — AppSource.decryptSpadeUrl
- packages/api/lib/src/video_model_client.dart — AppSource payload/signing/selection
- packages/api/lib/src/catalog.dart — Client / WebSource request and parsing semantics
- packages/core/lib/src/media/ — ISO BMFF/CENC implementation informed by core/mp4.js;
  subsample processing and offset-preserving free-box conversion implemented in Dart
- tool/generate_media_fixtures.cjs — adapts the original synthetic Mp4Fixture and
  generates real H.264/AAC test media locally using ffmpeg

The oracle fixture contains synthetic inputs, existing offline test vectors,
and outputs from the local source. Its sourceSha256 field identifies the exact
PureSign input file. No account tokens, API keys or .env data were copied from
the reference Flutter project.

## Multi-source adapters (P1–P3)

The multi-source adapter protocol behavior is informed by the locally supplied
hongguo-drama reference (GPL-3.0). Only public HTTP request/response shapes and
normalization semantics were adapted; no GPL signing keys, constants, account
tokens or .env data were copied. The interface and ID namespace are our own
contract (see docs/contracts/), and the dispatch is a registry rather than the
reference's hardcoded if/else chain.

Protocol ancestry of the individual upstream sites:
- Xifan / Hema: public portalPage / aggregationPage / `__NEXT_DATA__` page shapes.
- DramaBox: public English SSR pages, adapted in the reference from
  zuomeizuoyang/shortdrama-player (MIT, commit 081e7ee7).
- ReelShort: public page routes/schema, adapted in the reference from
  wanglinsaputra/Rest-Api-ReelShort (MIT).
- Custom sources: the public 苹果 CMS (Apple CMS) VOD API convention.

The HLS channel is intentionally not implemented; see
docs/design/hls-channel-evaluation.md for the decision and evidence.

## Android account signing family (feature/api-alignment)

- packages/core/lib/src/crypto/account_sign.dart and
  packages/core/lib/src/crypto/account_sign_constants.dart are a pure Dart port
  of `references/hongguo-android` `account/protocol/Signer.kt`, `Bytes.kt`,
  `VendorConstants.kt` and `AesV3.kt` (GPL-3.0-only). That Kotlin code is itself
  adapted from tsukiyo-zero/hongguoTV commit 34c7930 and drpys commit 22261ad.
  The port is byte-compatible with the 12 pinned vectors in
  `app/src/test/java/com/hongguo/account/protocol/SigningOracleTest.kt`, copied
  as `packages/core/test/fixtures/account_signing_vectors.json`.
- This signing family is distinct from `pure_sign.dart`; it is not used for the
  legacy content/playback requests and must not be mixed into them.
