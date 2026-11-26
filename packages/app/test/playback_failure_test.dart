import 'dart:io' show HandshakeException;

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

  test('取源阶段 URL/密钥校验全败时归为片源地址被拒，仍可重试', () {
    final failure = PlaybackFailure.classify(
      StateError('No compatible media URL/key'),
    );
    expect(failure.kind, PlaybackFailureKind.sourceRejected);
    expect(failure.retryable, isTrue);
    expect(failure.headline, contains('片源地址'));
    expect(failure.hint, isNot(contains('离线')));
  });

  test('本地缓存缺失仍归为本地问题，与取源校验失败分开', () {
    final failure = PlaybackFailure.classify(StateError('该集本地缓存已不存在'));
    expect(failure.kind, PlaybackFailureKind.localMissing);
    expect(failure.retryable, isFalse);
  });

  test('TLS 握手被中断时不说成片源问题，仍给重试', () {
    for (final error in <Object>[
      const HandshakeException('Connection terminated during handshake'),
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.unknown,
        error: const HandshakeException(
          'Connection terminated during handshake',
        ),
      ),
    ]) {
      final failure = PlaybackFailure.classify(error);
      expect(failure.kind, PlaybackFailureKind.tlsHandshake, reason: '$error');
      expect(failure.retryable, isTrue);
      expect(failure.headline, isNot(contains('片源')));
      expect(failure.hint, contains('握手'));
      expect(failure.detail, isNotEmpty);
    }
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

  test('原生播放器字符串错误给出可重试的独立文案，平台消息留在详情', () {
    final failure = PlaybackFailure.classify(
      const PlaybackRuntimeError('MEDIA_ERROR_IO: 打开失败'),
    );
    expect(failure.kind, PlaybackFailureKind.unknown);
    expect(failure.headline, contains('播放器'));
    expect(failure.retryable, isTrue);
    expect(failure.detail, contains('MEDIA_ERROR_IO'));
  });

  test('首播自动重试只放行瞬时故障', () {
    for (final error in <Object>[
      const MetadataDeadlineExceeded(),
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionTimeout,
      ),
      DioException(
        requestOptions: RequestOptions(path: '/'),
        type: DioExceptionType.connectionError,
      ),
      const PlaybackUnavailable('三层都没有地址'),
      const IncompleteCatalogResponse('缺少 video_list'),
      const PlaybackRuntimeError('解码失败'),
    ]) {
      expect(isTransientFirstPlayFailure(error), isTrue, reason: '$error');
    }
    for (final error in <Object>[
      const RequestCancelled(),
      StateError('该集本地缓存已不存在'),
      StateError('No compatible media URL/key'),
      const FormatException('boom'),
    ]) {
      expect(isTransientFirstPlayFailure(error), isFalse, reason: '$error');
    }
  });

  test('首播自动重试是一次性的：出过画面、已重试、后台取消都不再重试', () {
    const failure = MetadataDeadlineExceeded();
    bool allowed({
      required bool tv,
      required bool played,
      required bool retryUsed,
      required bool interrupted,
      required bool backgrounded,
    }) => shouldRetryFirstPlay(
      error: failure,
      tv: tv,
      played: played,
      retryUsed: retryUsed,
      interrupted: interrupted,
      backgrounded: backgrounded,
    );
    expect(
      allowed(
        tv: true,
        played: false,
        retryUsed: false,
        interrupted: false,
        backgrounded: false,
      ),
      isTrue,
    );
    expect(
      allowed(
        tv: false,
        played: false,
        retryUsed: false,
        interrupted: false,
        backgrounded: false,
      ),
      isFalse,
      reason: '手机保持原样',
    );
    expect(
      allowed(
        tv: true,
        played: true,
        retryUsed: false,
        interrupted: false,
        backgrounded: false,
      ),
      isFalse,
      reason: '已经出过画面',
    );
    expect(
      allowed(
        tv: true,
        played: false,
        retryUsed: true,
        interrupted: false,
        backgrounded: false,
      ),
      isFalse,
      reason: '不能循环重试',
    );
    expect(
      allowed(
        tv: true,
        played: false,
        retryUsed: false,
        interrupted: true,
        backgrounded: false,
      ),
      isFalse,
      reason: '生命周期取消由回前台自己恢复',
    );
    expect(
      allowed(
        tv: true,
        played: false,
        retryUsed: false,
        interrupted: false,
        backgrounded: true,
      ),
      isFalse,
      reason: '后台不重启取源',
    );
  });
}
