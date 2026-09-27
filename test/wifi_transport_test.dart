import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuel_consumption_calculator/core/services/obd_transport.dart';

void main() {
  late ServerSocket server;
  late StreamController<Socket> clients;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    clients = StreamController<Socket>();
    server.listen(clients.add);
  });

  tearDown(() async {
    await server.close();
    unawaited(clients.close());
  });

  Future<(WifiObdTransport, Socket, List<String>)> openPair() async {
    final payloads = <String>[];
    final transport = WifiObdTransport(
      InternetAddress.loopbackIPv4.address,
      server.port,
    );
    await transport.open(onPayload: payloads.add);
    final adapter = await clients.stream.first;
    return (transport, adapter, payloads);
  }

  test('writes CR-terminated commands', () async {
    final (transport, adapter, _) = await openPair();
    final received = adapter.cast<List<int>>().transform(utf8.decoder).first;
    await transport.write('01 0C');
    expect(await received, '01 0C\r');
    await transport.close();
    adapter.destroy();
  });

  test(
    'delivers one cleaned payload per prompt, split across segments',
    () async {
      final (transport, adapter, payloads) = await openPair();
      adapter.add(utf8.encode('SEARCHING...\r41 0C '));
      await adapter.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(payloads, isEmpty);

      adapter.add(utf8.encode('1A F8\r\r>41 0D 3C\r\r>'));
      await adapter.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(payloads, [': 41 0C 1A F8', ': 41 0D 3C']);
      await transport.close();
      adapter.destroy();
    },
  );

  test('reports disconnected once the adapter drops the socket', () async {
    final (transport, adapter, _) = await openPair();
    expect(transport.isConnected, isTrue);
    adapter.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(transport.isConnected, isFalse);
    await transport.close();
  });

  test('an unreachable adapter is a retryable open error', () async {
    final port = server.port;
    await server.close();
    final transport = WifiObdTransport(
      InternetAddress.loopbackIPv4.address,
      port,
    );
    Object? error;
    try {
      await transport.open(onPayload: (_) {});
    } catch (err) {
      error = err;
    }
    expect(error, isA<SocketException>());
    expect(transport.isRetryableOpenError(error!), isTrue);
  });
}
