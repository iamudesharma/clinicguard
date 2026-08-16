/// shelf server: GET /health + WS /signal (one peer per connection).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'audio_core.dart';
import 'peer_session.dart';

/// Runs the voice call server. [coreFactory] creates one [AudioCore] per call.
Future<HttpServer> runVoiceCallServer({
  required AudioCore Function() coreFactory,
  int port = 8765,
  String host = '0.0.0.0',
}) async {
  final wsHandler = webSocketHandler((WebSocketChannel ws, String? protocol) {
    final peer = PeerSession(
      ws,
      DateTime.now().microsecondsSinceEpoch & 0xFFFF,
      coreFactory(),
    );
    unawaited(peer.start());
    ws.stream.listen(
      (data) => unawaited(peer.handleMessage(data as String)),
      onError: (_) => peer.close(),
      onDone: peer.close,
    );
  });

  Future<Response> handler(Request req) async {
    switch (req.url.path) {
      case 'health':
        return Response.ok(
          jsonEncode({'status': 'ok', 'transport': 'webrtc_dart'}),
          headers: {'content-type': 'application/json'},
        );
      case 'signal':
        return wsHandler(req);
      default:
        return Response.notFound(
          '{"status":"not_found"}',
          headers: {'content-type': 'application/json'},
        );
    }
  }

  final server = await shelf_io.serve(
    const Pipeline().addHandler(handler),
    InternetAddress.anyIPv4,
    port,
  );
  stdout.writeln('[voice_forge] http://$host:$port (ws /signal, GET /health)');
  return server;
}
