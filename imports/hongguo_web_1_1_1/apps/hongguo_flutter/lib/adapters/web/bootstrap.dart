import 'package:hongguo_core/hongguo_core.dart';
import '../backend.dart';
import '../http_transport.dart';

Future<Backend> createBackend() async {
  const configured = String.fromEnvironment('HONGGUO_API_BASE');
  const key = String.fromEnvironment('HONGGUO_API_KEY');
  final transport = HttpTransport();
  final repository = RemoteRepository(
    transport,
    configured.isEmpty ? Uri.base : Uri.parse(configured),
    apiKey: key,
  );
  return Backend(repository, repository, label: '远程服务', close: transport.close);
}
