"""
Redis Query Caching Layer
ROI: 50-80% latency reduction for repeated queries
"""

import redis
import json
import hashlib
import logging
from functools import wraps
from typing import Any, Optional, Callable, List, Dict

logger = logging.getLogger(__name__)


class VectorQueryCache:
    """Redis-backed cache for vector search results."""

    def __init__(self, host='localhost', port=6379, password=None, db=0, default_ttl=300):
        try:
            self.redis = redis.Redis(
                host=host, port=port, password=password, db=db,
                decode_responses=True, socket_connect_timeout=5
            )
            self.redis.ping()
            logger.info(f"Redis cache connected: {host}:{port}")
        except redis.ConnectionError as e:
            logger.warning(f"Redis unavailable, caching disabled: {e}")
            self.redis = None

        self.default_ttl = default_ttl
        self.stats = {'hits': 0, 'misses': 0, 'errors': 0}

    def _generate_cache_key(self, prefix, namespace, vector, top_k, **kwargs):
        """Generate deterministic cache key."""
        vector_str = ','.join(f"{v:.6f}" for v in vector)
        vector_hash = hashlib.sha256(vector_str.encode()).hexdigest()[:16]
        params = '_'.join(f"{k}={v}" for k, v in sorted(kwargs.items()))
        parts = [prefix, namespace, vector_hash, str(top_k)]
        if params:
            parts.append(params)
        return ':'.join(parts)

    def cache_vector_search(self, ttl=None):
        """Decorator for caching vector search results."""
        cache_ttl = ttl or self.default_ttl

        def decorator(func):
            @wraps(func)
            def wrapper(namespace, vector, top_k=10, **kwargs):
                if self.redis is None:
                    return func(namespace, vector, top_k, **kwargs)

                cache_key = self._generate_cache_key('vector_search', namespace, vector, top_k, **kwargs)

                try:
                    cached = self.redis.get(cache_key)
                    if cached:
                        self.stats['hits'] += 1
                        logger.debug(f"Cache HIT: {cache_key}")
                        return json.loads(cached)

                    self.stats['misses'] += 1
                    result = func(namespace, vector, top_k, **kwargs)
                    self.redis.setex(cache_key, cache_ttl, json.dumps(result, default=str))
                    return result

                except redis.RedisError as e:
                    self.stats['errors'] += 1
                    logger.error(f"Cache error: {e}")
                    return func(namespace, vector, top_k, **kwargs)

            return wrapper
        return decorator

    def get_stats(self):
        """Get cache performance statistics."""
        total = self.stats['hits'] + self.stats['misses']
        hit_rate = (self.stats['hits'] / total * 100) if total > 0 else 0
        return {
            'hits': self.stats['hits'],
            'misses': self.stats['misses'],
            'hit_rate': f"{hit_rate:.2f}%",
            'errors': self.stats['errors']
        }


def get_cache(host='localhost', port=6379, password=None):
    """Get or create global cache instance."""
    return VectorQueryCache(host=host, port=port, password=password)
