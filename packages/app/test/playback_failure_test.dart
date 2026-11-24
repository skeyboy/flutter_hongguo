import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_api/hongguo_api.dart';
import 'package:hongguo_app/playback/playback_failure.dart';

void main() {
  test('取源三层全败时归为片源缺失，并把来源清单留在详情', () {
    final failure = PlaybackFailure.classify(
      const PlaybackUnavailable('官网：HTTP 403；App：业务码 110001；旧接口：业务码 2'),
    );
    expect(failure.kind, PlaybackFailureKind.noSource);
    expect(failure.retryable, isTrue);
    // 第一眼看到的是人话，三层清单只在详情里。
    expect(failure.headline, isNot(contains('110001')));
    expect(failure.detail, contains('官网：HTTP 403'));
    expect(failure.detail, contains('旧接口'));
  });

  test('取消不算故障，也不给重试按钮', () {
    final failure = PlaybackFailure.classify(const RequestCancelled());
    expect(failure.kind, PlaybackFailureKind.cancelled);
    expect(failure.retryable, isFalse);
    expect(failure.headline, contains('取消'));
  });

  test('元数据超时与连接超时都归到超时，可重试', () {
    for (final error in <Object>[
      const MetadataDeadlineExceeded(),
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      ),
    ]) {
      final failure = PlaybackFailure.classify(error);
      expect(failure.kind, PlaybackFailureKind.timeout, reason: '$error');
      expect(failure.retryable, isTrue);
    }
  });

  test('结构不完整与服务端文案都归到信息不全', () {
    for (final error in <Object>[
      const IncompleteCatalogResponse('返回的数据缺少 video_list'),
      const CatalogError('无法获取分集'),
    ]) {
      final failure = PlaybackFailure.classify(error);
      expect(failure.kind, PlaybackFailureKind.incomplete, reason: '$error');
      expect(failure.detail, isNotEmpty);
    }
  });

  test('本地缓存读不出来时不建议重试', () {
    final failure = PlaybackFailure.classify(StateError('该集本地缓存已不存在'));
    expect(failure.kind, PlaybackFailureKind.localMissing);
    expect(failure.retryable, isFalse);
    expect(failure.detail, contains('本地缓存已不存在'));
  });

  test('网络层失败与未知异常分开表述', () {
    final network = PlaybackFailure.classify(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      ),
    );
    expect(network.kind, PlaybackFailureKind.network);

    final unknown = PlaybackFailure.classify(const FormatException('boom'));
    expect(unknown.kind, PlaybackFailureKind.unknown);
    expect(unknown.detail, contains('boom'));
  });
}
