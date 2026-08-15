/// Loopback core: decoded caller audio is re-encoded and sent straight back
/// (transport + codec test; no intelligence).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:voicepipe/voicepipe.dart';

class LoopbackCore implements AudioCore {
  final _out = StreamController<Int16List>();
  final _events = StreamController<Map<String, dynamic>>();

  @override
  void onDecodedPcm(Int16List pcm48kStereo) {
    _out.add(pcm48kStereo);
  }

  @override
  Stream<Int16List> get outgoingPcm => _out.stream;

  @override
  void onDataMessage(Map<String, dynamic> message) {
    print('[loopback] data message: $message');
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  void onPeerClosed() {}

  @override
  void onDataChannelOpen() {}

  @override
  Map<String, dynamic>? get connectionInfo => null;

  void dispose() {
    _out.close();
    _events.close();
  }
}
