import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'merge_worker.dart';

/// One episode a compatible merge would re-encode, with only the facts the
/// encoder call needs. The table read that produces these lives in the worker
/// isolate ([MergeProbeEntry]); nothing here parses a file, so the whole lane is
/// unit-testable without a native FFmpeg on the machine.
class TranscodeSource {
  final String path;
  final int index;

  /// The frame the encode must reproduce: the coded size the sample entry
  /// states, falling back to the display hint only when it says nothing. 0 when
  /// the file has no video track at all.
  final int width, height, durationMs, bytes;

  /// This track's own average rate, bits per second; 0 = not measurable.
  final int videoBitrate, audioBitrate;

  /// Average frame rate × 1000 (29970 = 29.97); 0 = not measurable.
  final int fpsMilli;
  const TranscodeSource({
    required this.path,
    required this.index,
    required this.width,
    required this.height,
    required this.durationMs,
    this.bytes = 0,
    this.videoBitrate = 0,
    this.audioBitrate = 0,
    this.fpsMilli = 0,
  });

  bool get hasAudio => audioBitrate > 0;

  /// The whole file's average rate, the upward-guessing stand-in for a video
  /// track whose own samples could not be divided.
  int get containerBitrate =>
      durationMs <= 0 || bytes <= 0 ? 0 : bytes * 8000 ~/ durationMs;
}

/// The precheck's answer about one file, plus where that file sits. The size
/// travels with it is the coded frame the sample entry states.
TranscodeSource transcodeSourceOf(MergeProbeEntry entry, String path) =>
    TranscodeSource(
      path: path,
      index: entry.index,
      width: entry.width,
      height: entry.height,
      durationMs: entry.durationMs,
      bytes: entry.bytes,
      videoBitrate: entry.videoBitrate,
      audioBitrate: entry.audioBitrate,
      fpsMilli: entry.fpsMilli,
    );

/// The reason a selection cannot become a compatible merge, in the words the
/// panel shows. [planTranscode] throws it, so the sentence a viewer reads in the
/// panel is the sentence the lane itself would refuse on.
class TranscodeReject implements Exception {
  final String reason;
  const TranscodeReject(this.reason);
  @override
  String toString() => reason;
}

/// The merged encode: the size and rates every source is kept at, and the frame
/// rate they are all normalised to.
///
/// Under 画质优先 nothing here lowers a source. The resolution is the shared
/// source resolution (a difference is a refusal, not a scale), the rate is the
/// highest any source carries, and the frame rate only goes up -- never down --
/// so the fastest segment keeps every frame it has.
class TranscodePlan {
  final List<TranscodeSource> sources;
  final int width, height;

  /// Bits per second for the whole product.
  final int videoBitrate, audioBitrate;

  /// Milli-fps every video stream is normalised to; 0 leaves the streams alone.
  final int fpsMilli;

  /// False only when no source has an audio track, which is the one shape the
  /// concat filter cannot represent as `v=1:a=1`.
  final bool withAudio;
  const TranscodePlan({
    required this.sources,
    required this.width,
    required this.height,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.fpsMilli,
    this.withAudio = true,
  });

  int get totalDurationMs => sources.fold(0, (a, s) => a + s.durationMs);

  /// What the product is expected to weigh: the promised rates over the promised
  /// length, plus the container's own tables. A target, not a guarantee -- a VBV
  /// encoder writes under it whenever the picture is easy.
  int get expectedBytes {
    final rate = videoBitrate + (withAudio ? audioBitrate : 0);
    return (rate * totalDurationMs / 8000 * 1.03).round();
  }
}

/// Why this selection would not be a quality-preserving compatible merge, or null
/// when it would. The same rule the lane uses, so the panel can ask it before
/// anything is queued and never promise an encode it would not perform.
String? transcodeRejectOf(List<TranscodeSource> sources) {
  if (sources.length < 2) return '兼容合成至少需要两集';
  for (final source in sources) {
    if (source.width <= 0 || source.height <= 0) {
      return '第 ${source.index} 集读不到画面尺寸，无法确定兼容合成的目标画质';
    }
    if (source.durationMs <= 0) {
      return '第 ${source.index} 集读不到时长，无法确定兼容合成的目标码率';
    }
    // H.264 requires even dimensions, and honouring 画质优先 rules out the one
    // fix that would work: a scale to the nearest even size.
    if (source.width.isOdd || source.height.isOdd) {
      return '第 ${source.index} 集的画面是 ${source.width}×${source.height}，'
          '编码器要求偶数边长，而兼容合成不缩放画面';
    }
  }
  final lead = sources.first;
  for (final source in sources.skip(1)) {
    if (source.width != lead.width || source.height != lead.height) {
      return '第 ${source.index} 集是 ${source.width}×${source.height}，'
          '与第 ${lead.index} 集的 ${lead.width}×${lead.height} 不同；'
          '兼容合成不缩放画面，需要分开合成';
    }
  }
  // One silent segment beside one with sound is a filter graph the lane cannot
  // promise: `a=1` needs an audio stream for every input.
  final voiceless = sources.where((s) => !s.hasAudio).toList();
  if (voiceless.isNotEmpty && voiceless.length != sources.length) {
    return '第 ${voiceless.first.index} 集没有音轨，与有声的各集不能并成一片，需要分开合成';
  }
  return null;
}

/// The encode every source in [sources] can be given without losing quality.
///
/// Throws [TranscodeReject] for the cases [transcodeRejectOf] names, so a caller
/// that skipped the precheck still cannot build a command that breaks the rules.
TranscodePlan planTranscode(List<TranscodeSource> sources) {
  final reason = transcodeRejectOf(sources);
  if (reason != null) throw TranscodeReject(reason);
  int highest(int Function(TranscodeSource) of) {
    var best = 0;
    for (final source in sources) {
      final value = of(source);
      if (value > best) best = value;
    }
    return best;
  }

  // A rate is only unknown when a track is empty or too short to divide; that
  // source's container average takes over, and it contains the audio and every
  // box as well, so it can only over-allocate. Nothing is ever clamped down: an
  // expensive source is allowed the rate it already paid for.
  final video = highest(
    (s) => s.videoBitrate > 0 ? s.videoBitrate : s.containerBitrate,
  );
  final audio = highest((s) => s.audioBitrate);
  return TranscodePlan(
    sources: sources,
    width: sources.first.width,
    height: sources.first.height,
    videoBitrate: video > 0 ? video : _fallbackVideoBitrate,
    audioBitrate: audio > 0 ? audio : _defaultAudioBitrate,
    fpsMilli: highest((s) => s.fpsMilli),
    withAudio: sources.first.hasAudio,
  );
}

const int _fallbackVideoBitrate = 4000000;
const int _defaultAudioBitrate = 192000;

/// "30" for 30 fps, "29.97" for 29.97: ffmpeg takes a decimal rate, and a
/// trailing zero would only make the logged command harder to read.
String fpsLabel(int fpsMilli) {
  if (fpsMilli <= 0) return '';
  final text = (fpsMilli / 1000).toStringAsFixed(3);
  var end = text.length;
  while (text[end - 1] == '0') {
    end--;
  }
  return text[end - 1] == '.'
      ? text.substring(0, end - 1)
      : text.substring(0, end);
}

/// The FFmpeg command for [plan], as an argument array: no shell is involved, so
/// a path with spaces or a quote cannot change what runs.
///
/// The graph decodes each input, normalises it, and concatenates -- one pass,
/// one encode, one file. `+faststart` is the delivery the design promises: the
/// metadata a phone reads before the media, at the head of the product.
List<String> ffmpegArgs(
  TranscodePlan plan, {
  required String encoder,
  required String output,
}) {
  final rate = fpsLabel(plan.fpsMilli);
  final chain = StringBuffer();
  for (var i = 0; i < plan.sources.length; i++) {
    chain.write('[$i:v]');
    if (rate.isNotEmpty) chain.write('fps=$rate,');
    // 8-bit 4:2:0 is the ceiling H.264 itself has, so a 10-bit source is reduced
    // here because the target codec cannot carry it -- the one loss the
    // compatible lane accepts.
    chain.write('format=yuv420p,setsar=1[v$i];');
  }
  for (var i = 0; i < plan.sources.length; i++) {
    chain.write('[v$i]');
    if (plan.withAudio) chain.write('[$i:a]');
  }
  chain.write(
    'concat=n=${plan.sources.length}:v=1:a=${plan.withAudio ? 1 : 0}[v]',
  );
  if (plan.withAudio) chain.write('[a]');
  final maxrate = (plan.videoBitrate * 1.5).round();
  return [
    '-hide_banner',
    '-loglevel',
    'error',
    '-nostdin',
    '-y',
    for (final source in plan.sources) ...['-i', source.path],
    '-filter_complex',
    chain.toString(),
    '-map',
    '[v]',
    if (plan.withAudio) ...['-map', '[a]'],
    '-c:v',
    encoder,
    // A VBV window, not a fixed rate: the encoder may spend less on an easy
    // frame and more on a hard one, but never a lower average than the source.
    '-b:v',
    '${plan.videoBitrate}',
    '-maxrate',
    '$maxrate',
    '-bufsize',
    '${maxrate * 2}',
    if (plan.withAudio) ...['-c:a', 'aac', '-b:a', '${plan.audioBitrate}'],
    '-movflags',
    '+faststart',
    '-progress',
    'pipe:2',
    output,
  ];
}

/// The encoders to consider, best fit for 画质优先 first: the platform's own
/// hardware encoder where the build has one, software only as the fallback.
String? pickH264Encoder(
  Iterable<String> available, {
  required bool android,
  required bool apple,
  required bool windows,
}) {
  final known = available.toSet();
  final priority = <String>[
    if (android) 'h264_mediacodec',
    if (apple) 'h264_videotoolbox',
    if (windows) 'h264_mf',
    if (android) 'h264_v4l2m2m',
    'h264_nvenc',
    'h264_amf',
    'h264_qsv',
    'libx264',
  ];
  for (final name in priority) {
    if (known.contains(name)) return name;
  }
  // Anything else the build calls an H.264 encoder still beats refusing.
  return known.where((name) => name.startsWith('h264')).firstOrNull;
}

/// The names a `-encoders` listing advertises. A row reads
/// ` V..... h264_mf H.264 … (codec h264)`; the legend rows above the list start
/// the same way but name `=`, and only encoder rows carry `(codec `.
Set<String> encoderNames(String output) {
  final names = <String>{};
  for (final line in output.split('\n')) {
    if (!line.contains('(codec ')) continue;
    final cells = line.trim().split(RegExp(r'\s+'));
    if (cells.length < 2 || !RegExp(r'^[VAS]').hasMatch(cells[0])) continue;
    final name = cells[1];
    if (name != '=') names.add(name);
  }
  return names;
}

/// A running compatible merge: await [result], or [stop] it and the part file is
/// the viewer's to throw away. Unlike a lossless merge there is nothing to
/// resume from -- a re-encode restarts, which is what the task card says.
class TranscodeHandle {
  final Future<void> result;
  final void Function() stop;
  const TranscodeHandle({required this.result, required this.stop});
}

/// Why a compatible merge did not run, in a sentence for the task card.
class TranscodeFailure implements Exception {
  final String message;
  const TranscodeFailure(this.message);
  @override
  String toString() => message;
}

/// The fourcc values a product of the compatible lane is allowed to carry: an
/// H.264 sample entry, in either of the two annex-B/AVCC spellings. Anything
/// else in the read-back means the encode did not deliver what 兼容合成 promised,
/// and the job says so instead of publishing it.
const Set<String> h264Fourcc = {'avc1', 'avc3'};

/// The lane's only contact with a native FFmpeg: the app talks to this, and a
/// device either has one or does not.
abstract class MergeTranscoder {
  /// Whether a compatible merge can run right now. False until the build has
  /// been asked, which is why [warmUp] exists.
  bool get available;

  /// The encoder [ffmpegArgs] should be built with, or null when there is none.
  String? get encoder;

  /// What would run, shown in the panel and on the task card so the promise is
  /// auditable: `ffmpeg · h264_mf`, or the reason there is nothing to promise.
  String get label;

  /// Asks the machine once. Calling it again is cheap.
  Future<void> warmUp();

  /// Runs [args], reporting milliseconds of product written out of
  /// [totalDurationMs].
  TranscodeHandle run(
    List<String> args, {
    required int totalDurationMs,
    void Function(int doneMs, int totalMs)? onProgress,
  });

  void close();
}

/// How a process is started, injectable so the command shape and the progress
/// parsing are testable with no FFmpeg on the machine.
typedef TranscodeProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// The desktop lane: an FFmpeg the viewer already has, found on `PATH`.
///
/// This is the deliberate shape of 最稳定 for a first cut -- no bundled binary, no
/// license change, nothing new in the build chain, and the exact argument array
/// the Dart tests pin is what runs. Mobile cannot ship this way and still needs
/// a native FFmpeg (docs/design/video-merge.md, 二期设计); until that lands the
/// probe finds no executable there and the lane stays off.
class FfmpegTranscoder implements MergeTranscoder {
  final String executable;
  final TranscodeProcessStarter _start;

  Set<String> _encoders = const {};

  /// Whether the machine has answered the encoder question. The answer may still
  /// be that there is no encoder to find.
  bool _asked = false;
  Process? _running;

  FfmpegTranscoder({this.executable = 'ffmpeg', TranscodeProcessStarter? start})
    : _start = start ?? Process.start;

  @override
  String? get encoder => pickH264Encoder(
    _encoders,
    android: Platform.isAndroid,
    apple: Platform.isIOS || Platform.isMacOS,
    windows: Platform.isWindows,
  );

  @override
  bool get available => _asked && encoder != null;

  @override
  String get label {
    if (!_asked) return '正在检测 ffmpeg';
    return switch (encoder) {
      null => '未找到可用的 ffmpeg，或它不带 H.264 编码器，请改用无损合成',
      final name => 'ffmpeg · $name',
    };
  }

  @override
  Future<void> warmUp() async {
    if (available) return;
    try {
      final process = await _start(executable, const [
        '-hide_banner',
        '-encoders',
      ]);
      var collected = '';
      void append(List<int> chunk) =>
          collected = '$collected${utf8.decode(chunk, allowMalformed: true)}';
      final stdout = process.stdout.listen(append);
      final stderr = process.stderr.listen(append);
      final code = await process.exitCode;
      await stdout.cancel();
      await stderr.cancel();
      if (code != 0) return;
      _encoders = encoderNames(collected);
      _asked = true;
    } on ProcessException {
      // Nothing to ask: the machine answered that it has no ffmpeg. 无损 remains
      // the only lane, which is what the panel already shows before a probe.
      _encoders = const {};
      _asked = true;
    }
  }

  @override
  TranscodeHandle run(
    List<String> args, {
    required int totalDurationMs,
    void Function(int doneMs, int totalMs)? onProgress,
  }) {
    final result = Completer<void>();
    unawaited(
      _spawn(args, totalDurationMs, onProgress).then(
        (_) {
          if (!result.isCompleted) result.complete();
        },
        onError: (Object error) {
          if (result.isCompleted) return;
          result.completeError(
            error is TranscodeFailure
                ? error
                : TranscodeFailure('兼容合成未完成：$error'),
          );
        },
      ),
    );
    return TranscodeHandle(
      result: result.future,
      stop: () {
        _running?.kill();
        _running = null;
      },
    );
  }

  Future<void> _spawn(
    List<String> args,
    int totalDurationMs,
    void Function(int doneMs, int totalMs)? onProgress,
  ) async {
    final Process process;
    try {
      process = await _start(executable, args);
    } on ProcessException catch (e) {
      throw TranscodeFailure('无法启动 ffmpeg：${e.message}');
    }
    _running = process;
    final errors = <String>[];
    await for (final raw
        in process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final done = _progressMs(line);
      // `-progress pipe:2` shares this stream with the human-readable errors, so
      // everything that is not a progress key is what to say if this fails.
      if (done != null) {
        onProgress?.call(
          done > totalDurationMs ? totalDurationMs : done,
          totalDurationMs,
        );
        continue;
      }
      errors.add(line);
      if (errors.length > 12) errors.removeAt(0);
    }
    final code = await process.exitCode;
    _running = null;
    if (code != 0) {
      throw TranscodeFailure(
        'ffmpeg 未能完成合成（退出码 $code）：'
        '${errors.isEmpty ? '请查看 ffmpeg 的输出' : errors.last}',
      );
    }
  }

  @override
  void close() => _running?.kill();
}

/// How far along a `-progress` line says the encode is, in milliseconds, or null
/// when the line is not progress.
///
/// Both time keys are microseconds: `out_time_ms` is a long-standing misnomer in
/// ffmpeg, and `out_time_us` is the same number named honestly.
int? _progressMs(String line) {
  int? micros(String prefix) => int.tryParse(line.substring(prefix.length));
  for (final key in ['out_time_ms=', 'out_time_us=']) {
    if (!line.startsWith(key)) continue;
    final value = micros(key);
    return value == null ? null : value ~/ 1000;
  }
  if (line.startsWith('out_time=')) {
    final parts = line.substring('out_time='.length).split(':');
    if (parts.length != 3) return null;
    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final seconds = double.tryParse(parts[2]) ?? 0;
    return ((hours * 3600 + minutes * 60) * 1000 + (seconds * 1000)).round();
  }
  return null;
}

/// The answer a device with no FFmpeg gives: the lane is never available and
/// nothing is ever run. This is what mobile gets until a native build lands, and
/// what every platform gets before [MergeTranscoder.warmUp] has answered.
class UnavailableTranscoder implements MergeTranscoder {
  final String reason;
  const UnavailableTranscoder({this.reason = '这台设备没有可用的 ffmpeg，请改用无损合成'});

  @override
  bool get available => false;
  @override
  String? get encoder => null;
  @override
  String get label => reason;
  @override
  Future<void> warmUp() async {}
  @override
  TranscodeHandle run(
    List<String> args, {
    required int totalDurationMs,
    void Function(int doneMs, int totalMs)? onProgress,
  }) => TranscodeHandle(
    result: Future.error(const TranscodeFailure('这台设备没有可用的 ffmpeg，请改用无损合成')),
    stop: () {},
  );
  @override
  void close() {}
}
