/**
 * Basic Node.js example for Distributed PostgreSQL Cluster
 *
 * Demonstrates:
 * - Connecting to database
 * - Storing memory entries
 * - Retrieving entries
 * - Vector search
 *
 * Install: npm install pg dotenv
 * Run: node examples/nodejs_basic.js
 */

require('dotenv').config();
const { Pool } = require('pg');

// Create connection pool
const pool = new Pool({
    host: process.env.RUVECTOR_HOST || 'localhost',
    port: process.env.RUVECTOR_PORT || 5432,
    database: process.env.RUVECTOR_DB || 'distributed_postgres_cluster',
    user: process.env.RUVECTOR_USER || 'dpg_cluster',
    password: process.env.RUVECTOR_PASSWORD || 'dpg_cluster_2026',
    max: 20, // Connection pool size
});

/**
 * Store a memory entry
 */
async function storeMemory(namespace, key, value, embedding = null, metadata = {}, tags = []) {
    const embeddingStr = embedding ? `[${embedding.join(',')}]` : null;

    const query = `
        INSERT INTO memory_entries
            (namespace, key, value, embedding, metadata, tags)
        VALUES ($1, $2, $3, $4::ruvector, $5::jsonb, $6)
        ON CONFLICT (namespace, key) DO UPDATE
        SET value = EXCLUDED.value,
            embedding = EXCLUDED.embedding,
            metadata = EXCLUDED.metadata,
            tags = EXCLUDED.tags,
            updated_at = NOW()
    `;

    await pool.query(query, [namespace, key, value, embeddingStr, JSON.stringify(metadata), tags]);
}

/**
 * Retrieve a memory entry
 */
async function retrieveMemory(namespace, key) {
    const query = `
        SELECT namespace, key, value, metadata, tags, created_at, updated_at
        FROM memory_entries
        WHERE namespace = $1 AND key = $2
    `;

    const result = await pool.query(query, [namespace, key]);
    return result.rows[0] || null;
}

/**
 * Search by vector similarity
 */
async function searchMemory(namespace, queryEmbedding, limit = 10, minSimilarity = 0.7) {
    const embeddingStr = `[${queryEmbedding.join(',')}]`;

    const query = `
        SELECT
            namespace, key, value, metadata, tags,
            1 - (embedding <=> $2::ruvector(384)) as similarity,
            created_at
        FROM memory_entries
        WHERE namespace = $1
          AND embedding IS NOT NULL
          AND (1 - (embedding <=> $2::ruvector(384))) >= $3
        ORDER BY embedding <=> $2::ruvector(384)
        LIMIT $4
    `;

    const result = await pool.query(query, [namespace, embeddingStr, minSimilarity, limit]);
    return result.rows;
}

/**
 * Generate random embedding for demo
 */
function generateRandomEmbedding() {
    return Array.from({ length: 384 }, () => Math.random());
}

/**
 * Main example
 */
async function main() {
    console.log('=== Node.js Basic Example ===\n');

    const namespace = 'example_nodejs';

    try {
        // 1. Store entries
        console.log('1. Storing entries...');
        const embedding1 = generateRandomEmbedding();
        const embedding2 = generateRandomEmbedding();

        await storeMemory(
            namespace,
            'doc_1',
            'First document',
            embedding1,
            { source: 'nodejs' },
            ['test', 'example']
        );
        console.log('  ✓ Stored doc_1');

        await storeMemory(
            namespace,
            'doc_2',
            'Second document',
            embedding2,
            { source: 'nodejs' },
            ['test']
        );
        console.log('  ✓ Stored doc_2');

        // 2. Retrieve entry
        console.log('\n2. Retrieving doc_1...');
        const entry = await retrieveMemory(namespace, 'doc_1');
        if (entry) {
            console.log('  Key:', entry.key);
            console.log('  Value:', entry.value);
            console.log('  Metadata:', entry.metadata);
            console.log('  Tags:', entry.tags);
        }

        // 3. Vector search
        console.log('\n3. Performing vector search...');
        const results = await searchMemory(namespace, embedding1, 5, 0.5);
        console.log(`  Found ${results.length} results:`);
        results.forEach((result, i) => {
            console.log(`    ${i + 1}. ${result.key}: similarity=${result.similarity.toFixed(3)}`);
        });

        // 4. Cleanup
        console.log('\n4. Cleanup...');
        await pool.query('DELETE FROM memory_entries WHERE namespace = $1', [namespace]);
        console.log(`  ✓ Cleaned up namespace '${namespace}'`);

        console.log('\n=== Done! ===');

    } catch (error) {
        console.error('Error:', error);
    } finally {
        await pool.end();
    }
}

// Run if called directly
if (require.main === module) {
    main().catch(console.error);
}

module.exports = { storeMemory, retrieveMemory, searchMemory };
