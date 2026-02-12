# Redis Query Caching Layer

## Overview

Redis-backed query caching layer for distributed PostgreSQL cluster, providing 50-80% latency reduction for repeated vector search queries.

## Performance Metrics

**Realistic Benchmark Results:**
- **Hit Rate**: 80-95% (depending on workload)
- **Latency Reduction**: 99.6% for cached queries
- **Throughput Improvement**: 79% overall
- **Production Impact**: ~3000 hours/year compute savings at 10K queries/hour

**Latency Comparison:**
- Cold/Uncached: ~156ms (database query)
- Hot/Cached: <1ms (Redis lookup)
- P95: ~111ms
- P99: ~162ms

## Deployment

### Quick Start

```bash
# Start Redis
./scripts/start_redis.sh

# Verify deployment
docker ps --filter "name=redis-cache"
docker exec redis-cache redis-cli ping  # Should return PONG
```

### Manual Deployment

```bash
# Pull and run Redis
docker run -d \
  --name redis-cache \
  -p 6379:6379 \
  --restart unless-stopped \
  redis:7-alpine

# Verify
docker exec redis-cache redis-cli ping
```

### Environment Configuration

Add to `.env`:
```bash
# Redis Cache Configuration
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=          # Optional, leave empty for no auth
REDIS_DB=0               # Database number (0-15)
REDIS_TTL=300            # Cache TTL in seconds (5 minutes)
```

## Usage

### Python Integration

```python
from src.db.cache import get_cache

# Initialize cache (reads from .env)
cache = get_cache()

# Wrap vector search function
@cache.cache_vector_search(ttl=300)
def search_vectors(namespace: str, vector: List[float], top_k: int = 10):
    # Your vector search implementation
    return results

# Use as normal - caching is automatic
results = search_vectors("my_namespace", query_vector, top_k=10)

# Get cache statistics
stats = cache.get_stats()
print(f"Hit rate: {stats['hit_rate']}")
```

### Manual Cache Operations

```python
from src.db.cache import get_cache

cache = get_cache()

# Direct Redis access
cache.redis.set("key", "value", ex=60)  # 60 second TTL
value = cache.redis.get("key")

# Cache stats
stats = cache.get_stats()
# Returns: {'hits': N, 'misses': M, 'hit_rate': 'X.X%', 'errors': E}
```

## Testing

### Integration Tests

```bash
# Basic integration test
source venv/bin/activate
python3 scripts/test_redis_cache.py

# Realistic benchmark
python3 scripts/benchmark_redis_realistic.py
```

### Manual Testing

```bash
# Test Redis connectivity
redis-cli -h localhost -p 6379 ping

# Monitor cache in real-time
redis-cli -h localhost -p 6379 monitor

# Check memory usage
redis-cli -h localhost -p 6379 INFO memory

# View cache keys
redis-cli -h localhost -p 6379 KEYS "vector_search:*"

# Clear cache
redis-cli -h localhost -p 6379 FLUSHDB
```

## Monitoring

### Cache Statistics

```python
from src.db.cache import get_cache

cache = get_cache()
stats = cache.get_stats()

print(f"Cache Hits: {stats['hits']}")
print(f"Cache Misses: {stats['misses']}")
print(f"Hit Rate: {stats['hit_rate']}")
print(f"Errors: {stats['errors']}")
```

### Redis Metrics

```bash
# Memory usage
docker exec redis-cache redis-cli INFO memory | grep used_memory_human

# Connection stats
docker exec redis-cache redis-cli INFO clients

# Key count
docker exec redis-cache redis-cli DBSIZE

# Server uptime
docker exec redis-cache redis-cli INFO server | grep uptime_in_seconds
```

### Docker Logs

```bash
# View Redis logs
docker logs redis-cache

# Follow logs in real-time
docker logs -f redis-cache

# Last 100 lines
docker logs --tail 100 redis-cache
```

## Cache Strategies

### TTL Configuration

**Short TTL (60-300s)**: Fast-changing data
```python
cache = get_cache(ttl=60)  # 1 minute
```

**Medium TTL (300-3600s)**: Moderate update frequency (default)
```python
cache = get_cache(ttl=300)  # 5 minutes
```

**Long TTL (3600-86400s)**: Rarely changing data
```python
cache = get_cache(ttl=3600)  # 1 hour
```

### Cache Invalidation

```python
from src.db.cache import get_cache

cache = get_cache()

# Clear all cache
cache.redis.flushdb()

# Clear specific pattern
pattern = "vector_search:my_namespace:*"
for key in cache.redis.scan_iter(match=pattern):
    cache.redis.delete(key)

# Clear specific query
cache_key = cache._generate_cache_key("vector_search", "namespace", vector, 10)
cache.redis.delete(cache_key)
```

## Troubleshooting

### Redis Not Responding

```bash
# Check container status
docker ps -a --filter "name=redis-cache"

# Restart container
docker restart redis-cache

# Check logs for errors
docker logs --tail 50 redis-cache
```

### Cache Not Working

```python
# Verify Redis connection
from src.db.cache import get_cache

cache = get_cache()
if cache.redis is None:
    print("Redis unavailable - check connection")
else:
    print("Redis connected")

# Test basic operations
cache.redis.set("test", "value")
assert cache.redis.get("test") == "value"
```

### High Memory Usage

```bash
# Check memory usage
docker exec redis-cache redis-cli INFO memory

# Reduce TTL in .env
REDIS_TTL=60  # Shorter TTL = less memory

# Clear old data
docker exec redis-cache redis-cli FLUSHDB
```

### Low Hit Rate

Common causes:
1. **Unique queries**: Each query is different (expected)
2. **Short TTL**: Cache expiring too quickly
3. **Large parameter space**: Many combinations of top_k, filters, etc.
4. **Vector precision**: Small variations in vectors generate different keys

Solutions:
```python
# 1. Increase TTL
cache = get_cache(ttl=600)  # 10 minutes

# 2. Round vectors before caching
vector_rounded = [round(v, 4) for v in vector]

# 3. Reduce parameter variations
# Use consistent top_k values
```

## Architecture

### Cache Key Structure

```
vector_search:{namespace}:{vector_hash}:{top_k}[:param1=val1:param2=val2]
```

Example:
```
vector_search:documents:676411de7ee9321f:10
vector_search:images:a3f2c1d5e6b7a8f9:20:min_score=0.8
```

### Cache Flow

```
Query → Cache Key Generation → Redis Lookup
                                    ↓
                          ┌─────────┴─────────┐
                          │                   │
                        HIT                 MISS
                          │                   │
                    Return Cached      Execute Query
                                            ↓
                                      Store in Cache
                                            ↓
                                      Return Result
```

## Production Considerations

### Scaling

**Single Instance** (Current):
- Good for: <100K queries/day
- Memory: ~100MB-1GB
- Cost: Minimal

**Redis Cluster** (Future):
- Good for: >1M queries/day
- Memory: Distributed across nodes
- High availability

### Security

```bash
# Enable authentication (production)
docker run -d \
  --name redis-cache \
  -p 6379:6379 \
  -e REDIS_PASSWORD=your_secure_password \
  --restart unless-stopped \
  redis:7-alpine \
  redis-server --requirepass your_secure_password

# Update .env
REDIS_PASSWORD=your_secure_password
```

### Persistence

```bash
# Enable RDB snapshots
docker run -d \
  --name redis-cache \
  -p 6379:6379 \
  -v redis-data:/data \
  --restart unless-stopped \
  redis:7-alpine \
  redis-server --save 60 1000  # Save every 60s if 1000+ keys changed
```

### Monitoring & Alerts

```bash
# Set up monitoring with Redis exporter
docker run -d \
  --name redis-exporter \
  -p 9121:9121 \
  oliver006/redis_exporter \
  --redis.addr=redis://redis-cache:6379

# Integrate with Prometheus/Grafana for dashboards
```

## ROI Analysis

**Assumptions:**
- 10,000 queries/hour
- 80% cache hit rate
- 150ms saved per cached query
- $0.10/compute hour

**Annual Savings:**
- Compute hours saved: ~3,000 hours
- Cost savings: ~$300/year
- Infrastructure cost: ~$20/year (Redis hosting)
- **Net ROI**: $280/year (14x return)

**Plus:**
- Better user experience (faster queries)
- Reduced database load (enables scaling)
- Lower infrastructure costs

## References

- [Redis Documentation](https://redis.io/documentation)
- [Redis Python Client](https://redis-py.readthedocs.io/)
- [Cache Invalidation Strategies](https://redis.io/docs/manual/patterns/)
- [Distributed PostgreSQL Cluster Docs](./README.md)
