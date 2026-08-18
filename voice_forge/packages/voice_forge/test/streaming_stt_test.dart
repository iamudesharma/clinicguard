import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:voice_forge/src/speech/interfaces.dart';

/// Mock streaming STT that simulates partial/final transcript behavior.
class _MockStreamingStt implements VoicepipeStreamingSTT {
  final List<String> partials = [];
  String _finalText = '';

  @override
  String acceptFrame(Float32List frame) {
    // Simulate partial transcript improving over time.
    final partial = 'partial-${partials.length + 1}';
    partials.add(partial);
    return partial;
  }

  @override
  String finalize() {
    _finalText = 'hello world';
    partials.clear();
    return _finalText;
  }

  @override
  void reset() {
    partials.clear();
    _finalText = '';
  }

  @override
  void setLanguage(String lang) {}
}

void main() {
  group('VoicepipeStreamingSTT interface', () {
    test('acceptFrame returns partial transcripts', () {
      final stt = _MockStreamingStt();

      final p1 = stt.acceptFrame(Float32List(512));
      expect(p1, isNotEmpty);
      expect(stt.partials.length, 1);

      final p2 = stt.acceptFrame(Float32List(512));
      expect(p2, isNotEmpty);
      expect(stt.partials.length, 2);
    });

    test('finalize returns final transcript and resets stream', () {
      final stt = _MockStreamingStt();

      stt.acceptFrame(Float32List(512));
      stt.acceptFrame(Float32List(512));

      final result = stt.finalize();
      expect(result, equals('hello world'));
      expect(stt.partials, isEmpty);
    });

    test('reset clears state for new utterance', () {
      final stt = _MockStreamingStt();

      stt.acceptFrame(Float32List(512));
      stt.acceptFrame(Float32List(512));
      expect(stt.partials.length, 2);

      stt.reset();
      expect(stt.partials, isEmpty);

      stt.acceptFrame(Float32List(512));
      expect(stt.partials.length, 1);
    });

    test(
      'post-reset frames survive into the final transcript '
      '(regression: reset-then-finalize must not return empty)',
      () {
        final stt = _MockStreamingStt();

        // First utterance, then a barge-in reset (the agent's interrupt path).
        stt.acceptFrame(Float32List(512));
        stt.finalize();
        stt.reset();

        // The new utterance's audio is fed after the reset...
        stt.acceptFrame(Float32List(512));
        stt.acceptFrame(Float32List(512));

        // ...and finalize() must return the NEW utterance's text, not empty.
        final result = stt.finalize();
        expect(result, isNotEmpty);
        expect(stt.partials, isEmpty);
      },
    );
  });
}
