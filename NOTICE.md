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
