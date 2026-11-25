import 'package:hongguo_core/hongguo_core.dart';
import 'package:test/test.dart';

void main() {
  const credentials = AccountCredentials(
    websiteCookie: 'sessionid=website; sessionid_ss=website-ss',
    appDeviceCookie:
        'install_id=123; ttreq=1; store-region=cn; store-region-src=uid; '
        'device_token=must-not-leak',
    deviceId: '1905892595378490',
    installId: '1905892595382586',
    bizUserId: '7661622467441478681999999999',
    agw: true,
    generation: 7,
  );

  test('Cookie 按来源分域，设备 token 不进入任何请求头', () {
    expect(credentials.websiteHeaders, {'cookie': credentials.websiteCookie});
    expect(credentials.websiteHeaders['cookie'], isNot(contains('install_id')));
    expect(credentials.mediaHeaders['cookie'], contains('install_id=123'));
    expect(credentials.mediaHeaders['cookie'], isNot(contains('sessionid')));
    expect(credentials.mediaHeaders['cookie'], isNot(contains('device_token')));
    expect(credentials.accountRequestHeaders['cookie'], contains('sessionid'));
    expect(
      credentials.accountRequestHeaders['cookie'],
      contains('install_id=123'),
    );
    expect(
      credentials.accountRequestHeaders['cookie'],
      isNot(contains('device_token')),
    );
  });

  test('业务身份是不透明字符串，存储键按代次隔离', () {
    expect(credentials.bizUserId, isA<String>());
    expect(credentials.storageKey, 'account.v7');
    expect(credentials.copyWith(generation: 8).storageKey, 'account.v8');
    final roundTrip = AccountCredentials.fromJson(credentials.toJson());
    expect(roundTrip.bizUserId, credentials.bizUserId);
    expect(roundTrip.generation, 7);
    expect(roundTrip.agw, isTrue);
  });

  test('非法凭据被拒绝，且模型本身不发起网络请求', () {
    expect(
      () => const AccountCredentials(websiteCookie: 'a\nb').validate(),
      throwsFormatException,
    );
    expect(
      () => AccountCredentials(generation: -1).validate(),
      throwsFormatException,
    );
    expect(const AccountCredentials().isEmpty, isTrue);
  });
}
