// Test unitario de `LocalDownloadsService.saveFileToDownloads`.
//
// Mockea el `MethodChannel` `com.psk.hearing_aid/local_downloads`
// (`LocalDownloadsChannel.kt`) y verifica:
//   1. Camino feliz: el método invoca `saveFileToDownloads` con los args
//      correctos (sourcePath, filename, mimeType) y devuelve la ruta.
//   2. PlatformException nativa (SAVE_FAILED) → LocalDownloadsException.
//   3. Retorno null/empty del canal → LocalDownloadsException.
//
// 100% offline, determinista, sin device.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_aid_app/data/services/local_downloads_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.psk.hearing_aid/local_downloads');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('saveFileToDownloads invoca el canal con args correctos y devuelve ruta',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'Descargas/diag_20260612_101500.wav';
    });

    final service = LocalDownloadsService();
    final saved = await service.saveFileToDownloads(
      sourcePath: '/data/user/0/com.psk/files/diag_20260612_101500.wav',
      filename: 'diag_20260612_101500.wav',
      mimeType: 'audio/wav',
    );

    expect(saved, 'Descargas/diag_20260612_101500.wav');
    expect(calls.single.method, 'saveFileToDownloads');
    final args = calls.single.arguments as Map;
    expect(args['sourcePath'],
        '/data/user/0/com.psk/files/diag_20260612_101500.wav');
    expect(args['filename'], 'diag_20260612_101500.wav');
    expect(args['mimeType'], 'audio/wav');
  });

  test('PlatformException nativa se mapea a LocalDownloadsException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'SAVE_FAILED', message: 'disco lleno');
    });

    final service = LocalDownloadsService();
    expect(
      () => service.saveFileToDownloads(
        sourcePath: '/tmp/x.wav',
        filename: 'x.wav',
        mimeType: 'audio/wav',
      ),
      throwsA(isA<LocalDownloadsException>()),
    );
  });

  test('retorno null del canal lanza LocalDownloadsException', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    final service = LocalDownloadsService();
    expect(
      () => service.saveFileToDownloads(
        sourcePath: '/tmp/x.json',
        filename: 'x.json',
        mimeType: 'application/json',
      ),
      throwsA(isA<LocalDownloadsException>()),
    );
  });
}
