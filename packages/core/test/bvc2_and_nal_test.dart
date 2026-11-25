import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

Uint8List _ascii(String s) => Uint8List.fromList(convert.latin1.encode(s));

/// 造一个最小 stsd 布局：'stsd' 的 type 从索引 4 起，样本条目 type 在 +16。
Uint8List _headWithStsdTag(String tag, {bool withBv2C = false}) {
  // 前置 ≥32 字节（ftyp/free），随后 stsd 盒的 type 字段对齐到索引 4+。
  final prefix = _ascii('....ftypisom0000isomiso2....free');
  final stsdAt = prefix.length; // 's' of 'stsd'
  final out = <int>[
    ...prefix,
    ..._ascii('stsd'), // stsdAt..stsdAt+3
    ...List<int>.filled(
      12,
      0,
    ), // version/flags(4) + entry_count(4) + entry size(4)
    ..._ascii(tag), // 条目 type：相对 stsdAt 的 +16
  ];
  if (withBv2C) out.addAll(_ascii('bv2C'));
  expect(stsdAt, greaterThanOrEqualTo(4), reason: 'fixture sanity');
  return Uint8List.fromList(out);
}

void main() {
  group('ByteVC2 探测（对齐上游 isBvc2File）', () {
    test('私有配置盒 bv2C 命中', () {
      final head = _headWithStsdTag('avc1', withBv2C: true);
      expect(Mp4Cenc.isBvc2(head), isTrue);
    });

    test('减壳后样本条目 bvc2 / bv2C / vvc1 / vvi1 命中', () {
      for (final tag in ['bvc2', 'bv2C', 'vvc1', 'vvi1']) {
        expect(Mp4Cenc.isBvc2(_headWithStsdTag(tag)), isTrue, reason: tag);
      }
    });

    test('普通 H.264/HEVC 条目不误判', () {
      for (final tag in ['avc1', 'avc3', 'hvc1', 'hev1']) {
        expect(Mp4Cenc.isBvc2(_headWithStsdTag(tag)), isFalse, reason: tag);
      }
    });

    test('无 stsd / 过短头部按普通文件处理', () {
      expect(Mp4Cenc.isBvc2(Uint8List(16)), isFalse);
      expect(Mp4Cenc.isBvc2(_ascii('no box here just plain bytes')), isFalse);
    });
  });

  group('NAL 自证接受 Annex-B（对齐上游 avccSelfOk）', () {
    // H.264 IDR slice：forbidden_zero=0, type=5；后随一个非 IDR（type=1）。
    test('AVCC 长度前缀保持可用', () {
      final sample = Uint8List.fromList([0, 0, 0, 2, 0x65, 0x88]);
      expect(Mp4Cenc.validNalSample(sample, 4, 'avc1'), isTrue);
    });

    test('Annex-B 三字节起始码可用', () {
      final sample = Uint8List.fromList([0, 0, 1, 0x65, 0x88]);
      expect(Mp4Cenc.validNalSample(sample, 4, 'avc1'), isTrue);
    });

    test('Annex-B 四字节起始码 + 多 NAL 可用', () {
      final sample = Uint8List.fromList([
        0, 0, 0, 1, 0x65, 0x88, // IDR
        0, 0, 1, 0x41, 0x9a, // 非 IDR
      ]);
      expect(Mp4Cenc.validNalSample(sample, 4, 'avc1'), isTrue);
    });

    test('HEVC Annex-B 亦可用', () {
      // hvc1 NAL 头两字节：forbidden_zero=0, type>0
      final sample = Uint8List.fromList([0, 0, 1, 0x26, 0x01, 0x02]);
      expect(Mp4Cenc.validNalSample(sample, 4, 'hvc1'), isTrue);
    });

    test('非法 NAL 仍被拒', () {
      expect(
        Mp4Cenc.validNalSample(Uint8List.fromList([0, 0, 1, 0x80]), 4, 'avc1'),
        isFalse,
      );
      expect(
        Mp4Cenc.validNalSample(
          Uint8List.fromList([0, 0, 0, 2, 0x00, 0x00]),
          4,
          'avc1',
        ),
        isFalse,
      );
    });
  });
}
