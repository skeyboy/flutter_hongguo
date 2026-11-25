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

## Upstream 1.3.5 protocol comparison (2026-11-25)

The hongguo-web 1.3.5 comparison (commit c8b6c61e) was performed against
`docs/design/upstream-1.3.5-auth-codec-alignment.md`. Its portable playback
signer `server/src/core/thl-sign.js` is GPL-3.0-only and vendors code from
never88gone/THLRedGuo (tag `official-source`), with signing/spade ancestry from
jackotom/hongguo-drama (GPL-3.0), N3urda/hongguoTV and woshishiq1/drpys.
No thl-sign code, constants or lookup tables were copied into this project:
the Dart `PureSign` remains the byte-audited legacy six-header implementation
pinned by `node_oracle.json` against hongguo-web 1.1.5. Only public protocol
observations (BVC2 detection semantics, Annex-B NAL acceptance) were adapted
into our own pure-Dart media layer. See `tool/upstream_protocol_1_3_5.json`
for the recorded sha256 baseline.

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

- `lib/src/crypto/player_sign.dart` (`LegacyPlayerSign`) ports the legacy
  single-episode signer from the same reference repository:
  `app/src/main/java/com/hongguo/api/core/PlayerSign.java` (SPDX
  GPL-3.0-only; upstream synced from LiuWQ0809/hongguo-android 3eaf813,
  which credits Xanerix/guoapp ad8dc125). It emits x-gorgon / x-argus /
  x-ladon for `/novel/player/video_model/v1/` and is byte-for-byte checked
  against that file's pinned test vectors (`packages/core/test/
  player_sign_test.dart`).
- This family is independent of both `pure_sign.dart` and the v5 playback
  signer; do not mix signatures across request families.

## Android v5 playback signing and guest playback (feature/api-alignment)

- packages/core/lib/src/crypto/playback_sign.dart and
  packages/core/lib/src/crypto/playback_sign_constants.dart are a pure Dart port
  of `references/hongguo-android` `api/playback/Signer.kt`, `AesV3.kt`,
  `Bytes.kt`, `V5Constants.kt` and `VendorConstants.kt` (GPL-3.0-only), adapted
  from N3urda/hongguoTV commit 6672b55 and drpys commit 22261ad. The port is
  byte-compatible with the 4 carrier vectors in `signing-v5-carrier.json` and
  the 32 digest vectors in `signing-v5-f13.json`, copied unchanged into
  `packages/core/test/fixtures/`. It is a separate family from `account_sign.dart`
  (different AES sbox/tables, fixed mobileV5 hashF13 branch) and must not be
  mixed with it.
- packages/api/lib/src/v5_playback.dart adapts `api/playback/MobilePlayerV5.kt`
  (query order, gzip body, endpoints).
- The `webAnonymous` route and `parseGuestPlayerPage` in `web_source.dart`
  adapt `api/service/PublicEpisodeSource.java`; its pinned page/response vectors
  were transcribed into `packages/api/test/guest_playback_vectors_test.dart`.
