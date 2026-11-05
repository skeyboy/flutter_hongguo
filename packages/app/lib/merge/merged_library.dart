import 'dart:convert';
import 'dart:io';

/// One episode inside a merged product, exactly as the manifest records it.
///
/// The manifest is the only description a merged file has: an MP4 carries no
/// per-source markers, so 「查看构成」 reads this list, not the video.
class MergedItem {
  final String vid, quality, episodeTitle, dramaId, sourceName;
  final int index, sourceSize, sourceModifiedMs, durationMs, offsetMs;
  final DateTime addedAt;
  const MergedItem({
    required this.vid,
    required this.quality,
    required this.episodeTitle,
    required this.dramaId,
    required this.sourceName,
    required this.index,
    required this.sourceSize,
    required this.sourceModifiedMs,
    required this.durationMs,
    required this.offsetMs,
    required this.addedAt,
  });

  /// How the queue addresses the same file: a product holds one episode at one
  /// quality, and an append that would write it again is refused.
  String get key => '${vid}_$quality';

  Map<String, dynamic> toJson() => {
    'vid': vid,
    'quality': quality,
    'episodeTitle': episodeTitle,
    'dramaId': dramaId,
    'sourceFile': 'media-cache/$sourceName',
    'sourceSize': sourceSize,
    'sourceModifiedMs': sourceModifiedMs,
    'index': index,
    'durationMs': durationMs,
    'offsetMs': offsetMs,
    'addedAt': addedAt.toIso8601String(),
  };

  factory MergedItem.fromJson(Map<String, dynamic> json) => MergedItem(
    vid: json['vid'] as String,
    quality: json['quality'] as String,
    episodeTitle: json['episodeTitle'] as String? ?? '',
    dramaId: json['dramaId'] as String? ?? '',
    sourceName: (json['sourceFile'] as String? ?? '').split('/').last,
    index: json['index'] as int? ?? 0,
    sourceSize: json['sourceSize'] as int? ?? 0,
    sourceModifiedMs: json['sourceModifiedMs'] as int? ?? 0,
    durationMs: json['durationMs'] as int? ?? 0,
    offsetMs: json['offsetMs'] as int? ?? 0,
    addedAt:
        DateTime.tryParse(json['addedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  MergedItem copyWith({int? offsetMs, int? durationMs}) => MergedItem(
    vid: vid,
    quality: quality,
    episodeTitle: episodeTitle,
    dramaId: dramaId,
    sourceName: sourceName,
    index: index,
    sourceSize: sourceSize,
    sourceModifiedMs: sourceModifiedMs,
    durationMs: durationMs ?? this.durationMs,
    offsetMs: offsetMs ?? this.offsetMs,
    addedAt: addedAt,
  );
}

/// One delivered copy. [mode] is `new` or `append`, and [targetOf] names the
/// export record an append grew, so the history stays readable after the file
/// has been moved by the viewer.
class MergedExport {
  final String path, mode;
  final String? targetOf;
  final DateTime at;
  final int bytes;
  const MergedExport({
    required this.path,
    required this.mode,
    required this.at,
    required this.bytes,
    this.targetOf,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'at': at.toIso8601String(),
    'mode': mode,
    'targetOf': targetOf,
    'bytes': bytes,
  };

  factory MergedExport.fromJson(Map<String, dynamic> json) => MergedExport(
    path: json['path'] as String,
    mode: json['mode'] as String? ?? 'new',
    targetOf: json['targetOf'] as String?,
    bytes: json['bytes'] as int? ?? 0,
    at:
        DateTime.tryParse(json['at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  /// A delivery the viewer may have moved or deleted outside the app: the
  /// record stays, the status says what is true now.
  bool get present => File(path).existsSync();
}

/// A merged resource: one MP4 plus the manifest that says what is in it.
class MergedVideo {
  final String mergeId, title, filePath;
  final String? codec;
  final int width, height, bytes;
  final DateTime createdAt, updatedAt;
  final List<MergedItem> items;
  final List<MergedExport> exports;

  /// `lossless` means every media byte is the download's own; `compatible` means
  /// the whole product was re-encoded into one H.264 stream so a device without
  /// the source codec can still play it. The viewer copies these files onto other
  /// phones, so the manifest says which promise the bytes keep.
  final String mode;
  const MergedVideo({
    required this.mergeId,
    required this.title,
    required this.filePath,
    required this.createdAt,
    required this.updatedAt,
    this.codec,
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
    this.items = const [],
    this.exports = const [],
    this.mode = 'lossless',
  });

  bool get isCompatible => mode == 'compatible';

  int get durationMs =>
      items.isEmpty ? 0 : items.last.offsetMs + items.last.durationMs;

  bool contains(String vid, String quality) =>
      items.any((i) => i.vid == vid && i.quality == quality);

  MergedVideo withExports(List<MergedExport> exports) => MergedVideo(
    mergeId: mergeId,
    title: title,
    filePath: filePath,
    codec: codec,
    width: width,
    height: height,
    bytes: bytes,
    createdAt: createdAt,
    updatedAt: updatedAt,
    items: items,
    exports: exports,
    mode: mode,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'mergeId': mergeId,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'codec': codec,
    'width': width,
    'height': height,
    'mode': mode,
    'items': items.map((i) => i.toJson()).toList(),
    'exports': exports.map((e) => e.toJson()).toList(),
  };

  /// A manifest read off disk: [filePath] and [bytes] describe the video that
  /// sits next to it, which is what the listing plays and reports.
  factory MergedVideo.parse(
    String mergeId,
    Map<String, dynamic> json, {
    required String filePath,
    required int bytes,
  }) => MergedVideo(
    mergeId: json['mergeId'] as String? ?? mergeId,
    title: json['title'] as String? ?? '合并视频',
    filePath: filePath,
    codec: json['codec'] as String?,
    width: json['width'] as int? ?? 0,
    height: json['height'] as int? ?? 0,
    bytes: bytes,
    mode: json['mode'] as String? ?? 'lossless',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    items: [
      for (final item in (json['items'] as List? ?? const []))
        MergedItem.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
    exports: [
      for (final record in (json['exports'] as List? ?? const []))
        MergedExport.fromJson(Map<String, dynamic>.from(record as Map)),
    ],
  );
}

/// The `merged/` directory: products and their manifests, read as one list.
///
/// Every product owns two files, `<id>.mp4` and `<id>.merge.json`. A manifest
/// whose video is gone is dropped from the listing -- there is nothing to play
/// or to deliver -- and an orphan video is left alone until the viewer clears
/// the directory.
class MergedLibrary {
  final Directory directory;
  MergedLibrary(this.directory);

  String pathFor(String mergeId) => '${directory.path}/$mergeId.mp4';
  File manifestFor(String mergeId) =>
      File('${directory.path}/$mergeId.merge.json');

  /// Adds a delivery record and rewrites the manifest, so the export history
  /// survives in the same file the composition is read from.
  Future<MergedVideo> recordExport(
    MergedVideo video,
    MergedExport record,
  ) async {
    final grown = video.withExports([...video.exports, record]);
    await write(grown);
    return grown;
  }

  Future<void> write(MergedVideo video) async {
    await directory.create(recursive: true);
    final manifest = manifestFor(video.mergeId);
    final temporary = File(
      '${manifest.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(jsonEncode(video.toJson()), flush: true);
    if (manifest.existsSync()) await manifest.delete();
    await temporary.rename(manifest.path);
  }

  Future<void> delete(String mergeId) async {
    final video = File(pathFor(mergeId));
    if (video.existsSync()) await video.delete();
    final manifest = manifestFor(mergeId);
    if (manifest.existsSync()) await manifest.delete();
  }

  Future<MergedVideo?> read(String mergeId) async {
    final manifest = manifestFor(mergeId);
    final file = File(pathFor(mergeId));
    if (!await manifest.exists() || !await file.exists()) return null;
    try {
      return MergedVideo.parse(
        mergeId,
        Map<String, dynamic>.from(
          jsonDecode(await manifest.readAsString()) as Map,
        ),
        filePath: file.path,
        bytes: await file.length(),
      );
    } on FormatException {
      return null;
    }
  }

  Future<List<MergedVideo>> list() async {
    if (!await directory.exists()) return const [];
    const suffix = '.merge.json';
    final out = <MergedVideo>[];
    await for (final entry in directory.list()) {
      final name = entry.uri.pathSegments.last;
      if (entry is! File || !name.endsWith(suffix)) continue;
      final id = name.substring(0, name.length - suffix.length);
      final file = File(pathFor(id));
      if (!await file.exists()) continue;
      try {
        out.add(
          MergedVideo.parse(
            id,
            Map<String, dynamic>.from(
              jsonDecode(await entry.readAsString()) as Map,
            ),
            filePath: file.path,
            bytes: await file.length(),
          ),
        );
      } on FormatException {
        continue;
      }
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }
}
