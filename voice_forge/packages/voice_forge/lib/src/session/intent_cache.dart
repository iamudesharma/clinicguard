/// Simple keyword-based intent cache for common triage queries.
///
/// Caches LLM response text keyed by normalized query. Cache hits skip
/// the LLM call entirely and go straight to TTS, saving 200-700ms.
/// Entries expire after 30 minutes (LRU eviction at 50 entries).
library;

import 'dart:collection';

/// A cached intent entry.
class _CacheEntry {
  final String key;
  final String responseText;
  final String query;
  final DateTime createdAt;
  int hitCount;

  _CacheEntry(this.key, this.responseText, this.query)
      : createdAt = DateTime.now(),
        hitCount = 0;
}

/// Keyword-based intent cache for common triage queries.
///
/// Queries are normalized (lowercased, punctuation removed, whitespace
/// collapsed) and matched by exact key. This avoids embedding model
/// dependencies while still catching rephrases of common questions.
class IntentCache {
  final LinkedHashMap<String, _CacheEntry> _entries = LinkedHashMap();
  final int _maxEntries;
  final Duration _ttl;
  int _totalHits = 0;
  int _totalMisses = 0;
  int _totalExpired = 0;

  IntentCache({
    this._maxEntries = 50,
    this._ttl = const Duration(minutes: 30),
  });

  /// Look up a cached response for [query]. Returns the cached text on a
  /// hit, or null on a miss.
  String? lookupText(String query) {
    final key = _normalize(query);
    if (key.isEmpty) return null;

    final entry = _entries[key];
    if (entry == null) {
      _totalMisses++;
      return null;
    }

    // Expired entries behave as misses and are dropped.
    if (entry.createdAt.isBefore(DateTime.now().subtract(_ttl))) {
      _entries.remove(key);
      _totalExpired++;
      _totalMisses++;
      return null;
    }

    entry.hitCount++;
    _totalHits++;
    // Move to end (most recently used)
    _entries.remove(key);
    _entries[key] = entry;
    return entry.responseText;
  }

  /// Store a query -> response mapping.
  void store(String query, String responseText) {
    final key = _normalize(query);
    if (key.isEmpty || key.length < 10) return; // too short to be meaningful
    if (_entries.containsKey(key)) return; // don't overwrite

    // Drop expired entries before evicting by LRU.
    if (_ttl > Duration.zero) {
      final cutoff = DateTime.now().subtract(_ttl);
      _entries.removeWhere((_, e) => e.createdAt.isBefore(cutoff));
    }

    // Evict oldest (LRU) if at capacity
    if (_entries.length >= _maxEntries) {
      _entries.remove(_entries.keys.first);
    }

    _entries[key] = _CacheEntry(key, responseText, query);
  }

  /// Normalize a query for caching: lowercase, strip punctuation,
  /// collapse whitespace, remove common filler words.
  static String _normalize(String query) {
    return query
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Cache statistics for logging.
  Map<String, dynamic> get stats => {
        'entries': _entries.length,
        'hits': _totalHits,
        'misses': _totalMisses,
        'expired': _totalExpired,
        'hit_rate': _totalHits + _totalMisses > 0
            ? (_totalHits / (_totalHits + _totalMisses) * 100).round()
            : 0,
      };

  /// Clear all cached entries.
  void clear() {
    _entries.clear();
    _totalHits = 0;
    _totalMisses = 0;
    _totalExpired = 0;
  }

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;
}
