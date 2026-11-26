import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hongguo_api/hongguo_api.dart';

/// 取源链路现在有三层（官网直链 → App 签名 → 旧接口），失败时抛出的异常类型
/// 决定了用户还能做什么。这里把类型翻译成「一句原因 + 一句下一步」，原始异常
/// 文本（可能含三层来源清单）只留给「详情」，不摆到第一眼。
enum PlaybackFailureKind {
  /// 用户自己切走或换集导致的取消，不是故障。
  cancelled,

  /// 请求预算或连接超时：重试有意义。
  timeout,

  /// 三层都没有可用片源：重试、换集，或换个清晰度。
  noSource,

  /// 服务端回了业务码 / 结构不完整：重试通常能恢复。
  incomplete,

  /// 片源 URL 或内容密钥所有候选都没通过白名单/解密校验。这是取源阶段的
  /// 失败，不是本地文件坏了；重试、换清晰度或升级版本才有意义。
  sourceRejected,

  /// 本地缓存缺失或读不出来：只能换源，重试无用。
  localMissing,

  /// 网络层直接失败（断网、代理、DNS）。
  network,

  /// HTTPS 握手被对端或代理中断：连接还没建立，跟片源好坏无关。
  /// Dart 3.47 起 HandshakeException 不是 SocketException，Dio 会把它包成
  /// type=unknown 的 DioException，必须按内层异常识别。
  tlsHandshake,

  unknown,
}

/// 取源成功后原生播放器自己报出的失败。TV 的 video_player 只把平台消息以
/// 字符串交给上层，包一层才能像其它失败一样进入分类与「详情」。
class PlaybackRuntimeError implements Exception {
  final String message;
  const PlaybackRuntimeError(this.message);
  @override
  String toString() => message;
}

/// 播放失败的用户侧表述。
class PlaybackFailure {
  /// 分类结果，调用方据此决定给哪些按钮。
  final PlaybackFailureKind kind;

  /// 一句人话的原因，直接替换原来的「暂时无法播放」副标题。
  final String headline;

  /// 一句下一步建议。
  final String hint;

  /// 原始异常文本，折叠在「详情」里。
  final String detail;

  const PlaybackFailure({
    required this.kind,
    required this.headline,
    required this.hint,
    required this.detail,
  });

  /// 重试按钮是否值得给：取消和本地缺文件都不是重试能解决的。
  bool get retryable =>
      kind != PlaybackFailureKind.cancelled &&
      kind != PlaybackFailureKind.localMissing;

  factory PlaybackFailure.classify(Object error) {
    final detail = switch (error) {
      PlaybackUnavailable(:final message) => message,
      PlaybackRuntimeError(:final message) => message,
      CatalogError(:final message) => message,
      IncompleteCatalogResponse(:final message) => message,
      _ => '$error',
    };
    if (error is RequestCancelled) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.cancelled,
        headline: '这次准备已取消',
        hint: '重新准备即可继续观看。',
        detail: detail,
      );
    }
    if (error is MetadataDeadlineExceeded) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.timeout,
        headline: '取片源超时了',
        hint: '网络响应太慢，稍等一下再重试。',
        detail: detail,
      );
    }
    if (error is PlaybackRuntimeError) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.unknown,
        headline: '播放器没能打开这一集',
        hint: '取源已经成功，重试一次通常能恢复；一直如此可以换一集或换清晰度。',
        detail: detail,
      );
    }
    if (error is PlaybackUnavailable) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.noSource,
        headline: '这几层来源都没给可播放的地址',
        hint: '官网、App 和备用接口都试过了，重试或换一集通常可以绕开。',
        detail: detail,
      );
    }
    if (error is IncompleteCatalogResponse || error is CatalogError) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.incomplete,
        headline: '片源信息这次没取全',
        hint: '服务端返回的结构不完整，重试一般就恢复。',
        detail: detail,
      );
    }
    if (error is StateError) {
      // selectTrack 在三层来源都过不了 URL/密钥校验时抛的不是网络异常，
      // 而是 StateError('No compatible media URL/key')。它发生在取源阶段，
      // 不能按「本地缓存读不出来」处理：那样还会把重试按钮藏掉。
      if (_sourceRejected(error)) {
        return PlaybackFailure(
          kind: PlaybackFailureKind.sourceRejected,
          headline: '片源地址不被支持',
          hint: '这几层来源的下载地址都没能通过校验。试试换清晰度或换一集；一直如此请更新到最新版并反馈。',
          detail: detail,
        );
      }
      return PlaybackFailure(
        kind: PlaybackFailureKind.localMissing,
        headline: '本地这份缓存读不出来了',
        hint: '离线播放只认本地文件，请联网重新准备或改看其他集。',
        detail: detail,
      );
    }
    if (isHandshakeFailure(error)) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.tlsHandshake,
        headline: '加密连接没建立起来',
        hint: 'HTTPS 握手被中断，并不是片源失效。检查代理/VPN、系统时间和网络安全软件，换个网络再重试。',
        detail: detail,
      );
    }
    final dio = error is DioException ? error : null;
    if (dio != null && _timedOut(dio)) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.timeout,
        headline: '连接超时了',
        hint: '检查网络后重试，或先换一集看着。',
        detail: detail,
      );
    }
    if (dio != null || error is SocketException || error is TimeoutException) {
      return PlaybackFailure(
        kind: PlaybackFailureKind.network,
        headline: '网络这边断了',
        hint: '确认网络或代理可用后再重试。',
        detail: detail,
      );
    }
    return PlaybackFailure(
      kind: PlaybackFailureKind.unknown,
      headline: '这一集没能准备好',
      hint: '重试一次；如果一直这样，可以点开详情看看具体原因。',
      detail: detail,
    );
  }

  static bool _sourceRejected(StateError error) =>
      error.message.contains('No compatible media URL/key') ||
      error.message.contains('media URL/key');

  static bool _timedOut(DioException error) =>
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.error is TimeoutException;
}

/// 首次播放失败里，哪些值得「再取一次源」——TV 没有边下边看的早通道，
/// 整段下载/解密/校验都在首帧之前，瞬时超时或网络抖动很常见。
/// 取消、本地缺文件、地址被拒（该换清晰度/跨源）都不在此列。
bool isTransientFirstPlayFailure(Object error) {
  if (error is PlaybackRuntimeError) return true;
  final kind = PlaybackFailure.classify(error).kind;
  return kind == PlaybackFailureKind.timeout ||
      kind == PlaybackFailureKind.network ||
      kind == PlaybackFailureKind.noSource ||
      kind == PlaybackFailureKind.incomplete;
}

/// 一次性自动重试的准入条件。纯函数，便于把「不能循环/不能重试取消」钉在测试里。
///
/// [played] 已经出过画面就不再自动重试；[interrupted] 是生命周期切换造成的
/// 主动取消（回到前台会自己重播）；[backgrounded] 时也不该在后台重启取源。
bool shouldRetryFirstPlay({
  required Object error,
  required bool tv,
  required bool played,
  required bool retryUsed,
  required bool interrupted,
  required bool backgrounded,
}) =>
    tv &&
    !played &&
    !retryUsed &&
    !interrupted &&
    !backgrounded &&
    isTransientFirstPlayFailure(error);
