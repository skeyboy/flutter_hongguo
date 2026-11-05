import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_app/merge/merge_transcode.dart';
import 'package:hongguo_app/merge/merge_worker.dart';

TranscodeSource source({
  int index = 1,
  int width = 1080,
  int height = 1920,
  int durationMs = 60000,
  int bytes = 8 * 1024 * 1024,
  int videoBitrate = 3000000,
  int audioBitrate = 128000,
  int fpsMilli = 24000,
  String? path,
}) => TranscodeSource(
  path: path ?? '/media/${index}_best.mp4',
  index: index,
  width: width,
  height: height,
  durationMs: durationMs,
  bytes: bytes,
  videoBitrate: videoBitrate,
  audioBitrate: audioBitrate,
  fpsMilli: fpsMilli,
);

/// A process that is not FFmpeg: it emits the lines a test names and exits with
/// the code a test names, so the command handling can be checked on a machine
/// that has no FFmpeg at all.
class FakeProcess implements Process {
  final StreamController<List<int>> stderrController = StreamController();
  final StreamController<List<int>> stdoutController = StreamController();
  final Completer<int> exit = Completer<int>();
  List<String> signals = [];

  /// One stderr write, newline-terminated the way a real process ends a line.
  void say(String line) => stderrController.add(utf8.encode('$line\n'));

  void done(int code) {
    stderrController.close();
    stdoutController.close();
    exit.complete(code);
  }

  @override
  int get pid => 4242;
  @override
  Future<int> get exitCode => exit.future;
  @override
  Stream<List<int>> get stdout => stdoutController.stream;
  @override
  Stream<List<int>> get stderr => stderrController.stream;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal.name);
    return true;
  }
}

class FakeStarter {
  final calls = <List<String>>[];
  final processes = <FakeProcess>[];
  Object? throwOn;

  Future<Process> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    if (throwOn != null) throw throwOn!;
    final process = FakeProcess();
    processes.add(process);
    return process;
  }

  FakeProcess get last => processes.last;
}

/// The listing `ffmpeg -hide_banner -encoders` prints, trimmed to the rows that
/// matter plus the legend the parser must not read as an encoder.
const encodersListing = '''
FFmpeg version 7.1
Encoders:
 V..... = Video
 A..... = Audio
 S..... = Subtitle
 .F.... = Frame-level multithreading
 ..S... = Slice-level multithreading
 ..X... = Executes on lexicographical order
 .....G = Supports gamma correction
 V..... libx264  libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
 V..... h264_nvenc  NVIDIA NVENC H.264 encoder (codec h264)
 V..... h264_mf  H.264 (AT/Intel) (codec h264)
 A..... aac  AAC (Advanced Audio Coding) (codec aac)
''';

void main() {
  group('quality-first rules', () {
    test('a shared resolution and rates is accepted', () {
      final plan = planTranscode([source(), source(index: 2)]);
      expect(plan.width, 1080);
      expect(plan.height, 1920);
      expect(plan.videoBitrate, 3000000);
      expect(plan.audioBitrate, 128000);
      expect(plan.totalDurationMs, 120000);
      expect(plan.withAudio, isTrue);
    });

    test('nothing is lowered: the rate and the frame rate come from the best source', () {
      final plan = planTranscode([
        source(videoBitrate: 3000000, fpsMilli: 24000),
        source(index: 2, videoBitrate: 5500000, fpsMilli: 29970),
      ]);
      expect(plan.videoBitrate, 5500000);
      expect(plan.fpsMilli, 29970);
    });

    test('a resolution difference is a split, not a scale', () {
      expect(
        transcodeRejectOf([
          source(),
          source(index: 2, width: 720, height: 1280),
        ]),
        allOf(
          contains('第 2 集'),
          contains('720×1280'),
          contains('不缩放画面'),
          contains('分开合成'),
        ),
      );
    });

    test('an odd dimension is refused, because the fix would be a scale', () {
      expect(
        transcodeRejectOf([source(width: 1081), source(index: 2)]),
        contains('偶数边长'),
      );
    });

    test('a silent segment beside a voiced one is refused', () {
      expect(
        transcodeRejectOf([source(), source(index: 2, audioBitrate: 0)]),
        contains('没有音轨'),
      );
      // All silent is a shape the graph can express, so it is not a refusal.
      expect(
        transcodeRejectOf([
          source(audioBitrate: 0),
          source(index: 2, audioBitrate: 0),
        ]),
        isNull,
      );
    });

    test('one episode is not a merge', () {
      expect(transcodeRejectOf([source()]), contains('至少需要两集'));
    });

    test('the panel verdict and the lane are one rule', () {
      final accepted = [source(), source(index: 2)];
      expect(transcodeRejectOf(accepted), isNull);
      expect(() => planTranscode(accepted), returnsNormally);
      final refused = [source(), source(index: 2, width: 720)];
      expect(transcodeRejectOf(refused), isNotNull);
      expect(
        () => planTranscode(refused),
        throwsA(
          isA<TranscodeReject>().having(
            (e) => e.reason,
            'reason',
            transcodeRejectOf(refused),
          ),
        ),
      );
    });

    test('an unmeasurable track falls back upward, never to zero', () {
      // 8 MB over 60 s is about 1.1 Mbps for the whole file, which is more than
      // any single track of it can have cost.
      final plan = planTranscode([
        source(videoBitrate: 0, bytes: 8 * 1024 * 1024),
        source(index: 2, videoBitrate: 0, bytes: 8 * 1024 * 1024),
      ]);
      expect(plan.videoBitrate, greaterThan(1000000));
      expect(plan.videoBitrate, lessThan(2000000));
    });
  });

  group('the command', () {
    test('is one pass over every input, concatenated and re-encoded', () {
      final args = ffmpegArgs(
        planTranscode([source(), source(index: 2, fpsMilli: 30000)]),
        encoder: 'h264_mf',
        output: '/merged/m1.mp4',
      );
      expect(args, containsAllInOrder(['-i', '/media/1_best.mp4']));
      expect(args, containsAllInOrder(['-i', '/media/2_best.mp4']));
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(
        filter,
        '[0:v]fps=30,format=yuv420p,setsar=1[v0];'
        '[1:v]fps=30,format=yuv420p,setsar=1[v1];'
        '[v0][0:a][v1][1:a]concat=n=2:v=1:a=1[v][a]',
      );
      expect(args, containsAllInOrder(['-map', '[v]', '-map', '[a]']));
      expect(args, containsAllInOrder(['-c:v', 'h264_mf', '-b:v', '3000000']));
      // A VBV window over the promised average, so an easy frame does not
      // borrow from a hard one.
      expect(
        args,
        containsAllInOrder(['-maxrate', '4500000', '-bufsize', '9000000']),
      );
      expect(args, containsAllInOrder(['-c:a', 'aac', '-b:a', '128000']));
      expect(args, containsAllInOrder(['-movflags', '+faststart']));
      expect(args.last, '/merged/m1.mp4');
      expect(args.first, '-hide_banner');
    });

    test('never reaches for a shell, so a strange path is just a path', () {
      final args = ffmpegArgs(
        planTranscode([
          source(path: r'C:\合集\1" && del * .mp4'),
          source(index: 2, path: '/tmp/a b.mp4'),
        ]),
        encoder: 'libx264',
        output: '/tmp/out file.mp4',
      );
      expect(args, contains(r'C:\合集\1" && del * .mp4'));
      expect(args, contains('/tmp/a b.mp4'));
      expect(args, contains('-i'));
      expect(args.any((a) => a.contains('&&')), isTrue);
    });

    test('a silent selection encodes video alone', () {
      final args = ffmpegArgs(
        planTranscode([
          source(audioBitrate: 0),
          source(index: 2, audioBitrate: 0),
        ]),
        encoder: 'h264_mediacodec',
        output: '/merged/m1.mp4',
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, endsWith('concat=n=2:v=1:a=0[v]'));
      expect(args.contains('-c:a'), isFalse);
      expect(args.contains('[a]'), isFalse);
    });

    test('an unmeasurable frame rate leaves the streams alone', () {
      final args = ffmpegArgs(
        planTranscode([source(fpsMilli: 0), source(index: 2, fpsMilli: 0)]),
        encoder: 'libx264',
        output: '/merged/m1.mp4',
      );
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, isNot(contains('fps=')));
      expect(filter, contains('format=yuv420p'));
    });

    test('the rate label is what ffmpeg expects', () {
      expect(fpsLabel(30000), '30');
      expect(fpsLabel(29970), '29.97');
      expect(fpsLabel(23976), '23.976');
      expect(fpsLabel(0), '');
    });

    test('the write estimate follows the promised rates', () {
      final plan = planTranscode([
        source(durationMs: 60000),
        source(index: 2, durationMs: 60000, videoBitrate: 5000000),
      ]);
      // (5.0M + 0.128M) bps over 120 s is ~76.9 MB, and the container's tables
      // sit on top of that: a disk check has to be shown something a VBV encoder
      // will not exceed, so the estimate carries a margin, not a promise.
      expect(plan.expectedBytes, greaterThan(76920000));
      expect(plan.expectedBytes, lessThan(79300000));
    });
  });

  group('the encoder probe', () {
    test('reads encoder rows and skips the legend', () {
      final names = encoderNames(encodersListing);
      expect(names, containsAll(['libx264', 'h264_nvenc', 'h264_mf', 'aac']));
      expect(names.contains('='), isFalse);
      expect(names.contains('.'), isFalse);
    });

    test('prefers the platform encoder and keeps software last', () {
      const names = {'libx264', 'h264_nvenc', 'h264_mf', 'h264_videotoolbox'};
      expect(
        pickH264Encoder(names, android: true, apple: false, windows: false),
        'h264_nvenc',
      );
      expect(
        pickH264Encoder(names, android: false, apple: true, windows: false),
        'h264_videotoolbox',
      );
      expect(
        pickH264Encoder(names, android: false, apple: false, windows: true),
        'h264_mf',
      );
    });

    test('a build without any H.264 encoder has no compatible lane', () {
      expect(
        pickH264Encoder(
          {'hevc_videotoolbox', 'aac'},
          android: false,
          apple: true,
          windows: false,
        ),
        isNull,
      );
    });
  });

  group('the runner', () {
    test('becomes available only once the probe names an encoder', () async {
      final starter = FakeStarter();
      final transcoder = FfmpegTranscoder(start: starter.call);
      expect(transcoder.available, isFalse);
      expect(transcoder.label, contains('正在检测'));
      await probeWith(starter, transcoder);
      expect(transcoder.available, isTrue);
      // Which encoder wins depends on the machine the suite runs on; that the
      // label names one is the promise the panel shows.
      expect(transcoder.label, startsWith('ffmpeg · '));
      expect(starter.calls.first.first, 'ffmpeg');
    });

    test('a machine without ffmpeg stays unavailable and says why', () async {
      final starter = FakeStarter()
        ..throwOn = ProcessException('ffmpeg', const [], 'not found');
      final transcoder = FfmpegTranscoder(start: starter.call);
      await transcoder.warmUp();
      expect(transcoder.available, isFalse);
      expect(transcoder.label, isNotEmpty);
    });

    test('progress is reported in milliseconds of product', () async {
      final starter = FakeStarter();
      final transcoder = FfmpegTranscoder(start: starter.call);
      await probeWith(starter, transcoder);
      final done = <int>[];
      final handle = transcoder.run(
        const ['-i', 'a', 'out.mp4'],
        totalDurationMs: 120000,
        onProgress: (value, _) => done.add(value),
      );
      starter.last.say('frame=  120 fps= 30 out_time_ms=30000000 bitrate=N/A');
      starter.last.say('out_time_ms=30000000');
      starter.last.say('out_time_us=61000000');
      // Beyond the promised length is clamped: a card cannot read 120 %.
      starter.last.say('out_time_ms=200000000');
      starter.last.say('some encoder complained');
      starter.last.done(0);
      await handle.result;
      expect(done, [30000, 61000, 120000]);
    });

    test('a non-zero exit carries the last thing ffmpeg said', () async {
      final starter = FakeStarter();
      final transcoder = FfmpegTranscoder(start: starter.call);
      await probeWith(starter, transcoder);
      final handle = transcoder.run(const [
        '-i',
        'a',
        'out.mp4',
      ], totalDurationMs: 1000);
      starter.last.say(
        [
          'Some codecs may not be supported by this hardware encoder',
          'Error initializing output stream 0:0',
        ].join('\n'),
      );
      starter.last.done(1);
      expect(
        handle.result,
        throwsA(
          isA<TranscodeFailure>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('退出码 1'),
              contains('Error initializing output stream'),
            ),
          ),
        ),
      );
    });

    test('stopping kills the process', () async {
      final starter = FakeStarter();
      final transcoder = FfmpegTranscoder(start: starter.call);
      await probeWith(starter, transcoder);
      final handle = transcoder.run(const [
        '-i',
        'a',
        'out.mp4',
      ], totalDurationMs: 1000);
      // The process only exists once the spawn has been scheduled, which is the
      // same gap a real stop arrives into -- a pause pressed a moment later.
      await pumpEventQueue();
      handle.stop();
      expect(starter.last.signals, ['SIGTERM']);
      starter.last.done(0);
      await handle.result;
    });

    test('the unimplemented lane refuses instead of pretending', () async {
      final transcoder = const UnavailableTranscoder();
      expect(transcoder.available, isFalse);
      expect(transcoder.label, contains('ffmpeg'));
      expect(
        transcoder.run(const [], totalDurationMs: 1).result,
        throwsA(isA<TranscodeFailure>()),
      );
    });
  });

  group('the precheck feeds the lane', () {
    test('every fact a plan needs arrives with the entry', () {
      final entry = MergeProbeEntry(
        vid: '7000000000000000101',
        quality: 'best',
        index: 3,
        bytes: 12 * 1024 * 1024,
        durationMs: 45000,
        width: 1080,
        height: 1920,
        codec: 'hvc1',
        audioCodec: 'mp4a',
        videoBitrate: 4200000,
        audioBitrate: 96000,
        fpsMilli: 25000,
      );
      final roundTrip = MergeProbeEntry.fromJson(entry.toJson());
      expect(roundTrip.videoBitrate, 4200000);
      expect(roundTrip.audioBitrate, 96000);
      expect(roundTrip.fpsMilli, 25000);
      final spec = transcodeSourceOf(
        roundTrip,
        '/media/7000000000000000101_best.mp4',
      );
      expect(spec.index, 3);
      expect(spec.width, 1080);
      expect(spec.videoBitrate, 4200000);
      expect(spec.fpsMilli, 25000);
      expect(spec.path, '/media/7000000000000000101_best.mp4');
    });
  });
}

/// Answers the encoder probe [FfmpegTranscoder.warmUp] asks, so a run test can
/// start from a transcoder that is already available.
Future<void> probeWith(FakeStarter starter, FfmpegTranscoder transcoder) async {
  unawaited(transcoder.warmUp());
  await pumpEventQueue();
  starter.last.say(encodersListing);
  starter.last.done(0);
  await pumpEventQueue();
}
