import 'package:test/test.dart';
import 'package:voice_forge/src/session/intent_cache.dart';

void main() {
  group('IntentCache', () {
    test('stores and hits on normalized keys', () {
      final cache = IntentCache();
      cache.store('Do I need a doctor for a fever?', 'rest and hydrate');
      expect(cache.lookupText('do i need a doctor for a fever?'),
          'rest and hydrate');
      expect(cache.lookupText('  Do I need a doctor for a fever?! '),
          'rest and hydrate');
    });

    test('short queries are not cached', () {
      final cache = IntentCache();
      cache.store('hello', 'hi');
      expect(cache.lookupText('hello'), isNull);
    });

    test('does not overwrite existing entries', () {
      final cache = IntentCache();
      cache.store('Is my headache serious?', 'answer one');
      cache.store('Is my headache serious?', 'answer two');
      expect(cache.lookupText('Is my headache serious?'), 'answer one');
    });

    test('expires entries after the TTL', () async {
      final cache = IntentCache(ttl: const Duration(milliseconds: 20));
      cache.store('Should I go to the ER for chest pain?', 'call 911');
      expect(cache.lookupText('Should I go to the ER for chest pain?'),
          'call 911');
      // TTL is checked on lookup AND swept on store.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.lookupText('Should I go to the ER for chest pain?'), isNull);
      expect(cache.length, 0);
    });

    test('evicts oldest entry at capacity (LRU)', () {
      final cache = IntentCache(maxEntries: 2);
      cache.store('Question number one here', 'a');
      cache.store('Question number two here', 'b');
      cache.store('Question number three here', 'c');
      expect(cache.lookupText('Question number one here'), isNull);
      expect(cache.lookupText('Question number two here'), 'b');
      expect(cache.lookupText('Question number three here'), 'c');
    });

    test('stats track hits, misses and expired entries', () {
      final cache = IntentCache(ttl: const Duration(milliseconds: 1));
      cache.store('This is a long enough query', 'a');
      cache.lookupText('This is a long enough query');
      cache.lookupText('A completely different question here');
      final stats = cache.stats;
      expect(stats['hits'], 1);
      expect(stats['misses'], 1);
      expect(stats['entries'], 1);
    });
  });
}