-- RuVector Schema for Vector Memory and Pattern Learning
-- Compatible with PostgreSQL 14+ and RuVector extension

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS ruvector;

-- Main memory entries table with vector embeddings
CREATE TABLE IF NOT EXISTS memory_entries (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    key VARCHAR(255) NOT NULL,
    value TEXT,
    embedding ruvector(384),  -- 384-dimensional vectors (all-MiniLM-L6-v2)
    metadata JSONB DEFAULT '{}',
    tags TEXT[],
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP,
    UNIQUE(namespace, key)
);

-- Pattern learning table
CREATE TABLE IF NOT EXISTS patterns (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    pattern_type VARCHAR(100) NOT NULL,
    pattern_data JSONB NOT NULL,
    embedding ruvector(384),
    confidence FLOAT DEFAULT 0.5,
    success_count INTEGER DEFAULT 0,
    failure_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Pattern history for learning
CREATE TABLE IF NOT EXISTS pattern_history (
    id SERIAL PRIMARY KEY,
    pattern_id INTEGER REFERENCES patterns(id) ON DELETE CASCADE,
    action VARCHAR(50) NOT NULL,
    result VARCHAR(50) NOT NULL,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW()
);

-- Trajectories for ReasoningBank
CREATE TABLE IF NOT EXISTS trajectories (
    id SERIAL PRIMARY KEY,
    task_description TEXT NOT NULL,
    steps JSONB NOT NULL,
    verdict VARCHAR(50),
    quality_score FLOAT,
    embedding ruvector(384),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Graph nodes for relationships
CREATE TABLE IF NOT EXISTS graph_nodes (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    node_id VARCHAR(255) NOT NULL,
    node_type VARCHAR(100) NOT NULL,
    properties JSONB DEFAULT '{}',
    embedding ruvector(384),
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(namespace, node_id)
);

-- Graph edges for relationships
CREATE TABLE IF NOT EXISTS graph_edges (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    from_node VARCHAR(255) NOT NULL,
    to_node VARCHAR(255) NOT NULL,
    edge_type VARCHAR(100) NOT NULL,
    properties JSONB DEFAULT '{}',
    weight FLOAT DEFAULT 1.0,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Hyperbolic embeddings for hierarchical data
CREATE TABLE IF NOT EXISTS hyperbolic_embeddings (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    entity_id VARCHAR(255) NOT NULL,
    embedding ruvector(384),
    radius FLOAT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(namespace, entity_id)
);

-- Vector index metadata
CREATE TABLE IF NOT EXISTS vector_indexes (
    id SERIAL PRIMARY KEY,
    namespace VARCHAR(255) NOT NULL,
    index_name VARCHAR(255) NOT NULL,
    index_type VARCHAR(50) DEFAULT 'hnsw',
    dimensions INTEGER DEFAULT 384,
    metric VARCHAR(50) DEFAULT 'cosine',
    parameters JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(namespace, index_name)
);

-- Sessions table for compatibility
CREATE TABLE IF NOT EXISTS sessions (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(255) UNIQUE NOT NULL,
    data JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP
);

-- HNSW indexes for fast vector search (cosine distance)
CREATE INDEX IF NOT EXISTS idx_memory_embedding_hnsw
    ON memory_entries USING hnsw (embedding ruvector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_patterns_embedding_hnsw
    ON patterns USING hnsw (embedding ruvector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_trajectories_embedding_hnsw
    ON trajectories USING hnsw (embedding ruvector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_graph_nodes_embedding_hnsw
    ON graph_nodes USING hnsw (embedding ruvector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_hyperbolic_embedding_hnsw
    ON hyperbolic_embeddings USING hnsw (embedding ruvector_cosine_ops);

-- B-tree indexes for common queries
CREATE INDEX IF NOT EXISTS idx_memory_namespace ON memory_entries(namespace);
CREATE INDEX IF NOT EXISTS idx_memory_key ON memory_entries(key);
CREATE INDEX IF NOT EXISTS idx_memory_created_at ON memory_entries(created_at);
CREATE INDEX IF NOT EXISTS idx_memory_namespace_key ON memory_entries(namespace, key);

CREATE INDEX IF NOT EXISTS idx_patterns_namespace ON patterns(namespace);
CREATE INDEX IF NOT EXISTS idx_patterns_type ON patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_patterns_confidence ON patterns(confidence);

CREATE INDEX IF NOT EXISTS idx_graph_nodes_namespace ON graph_nodes(namespace);
CREATE INDEX IF NOT EXISTS idx_graph_nodes_type ON graph_nodes(node_type);

CREATE INDEX IF NOT EXISTS idx_graph_edges_namespace ON graph_edges(namespace);
CREATE INDEX IF NOT EXISTS idx_graph_edges_type ON graph_edges(edge_type);
CREATE INDEX IF NOT EXISTS idx_graph_edges_from ON graph_edges(from_node);
CREATE INDEX IF NOT EXISTS idx_graph_edges_to ON graph_edges(to_node);

-- GIN indexes for JSONB columns
CREATE INDEX IF NOT EXISTS idx_memory_metadata ON memory_entries USING gin(metadata);
CREATE INDEX IF NOT EXISTS idx_patterns_data ON patterns USING gin(pattern_data);
CREATE INDEX IF NOT EXISTS idx_trajectories_steps ON trajectories USING gin(steps);
CREATE INDEX IF NOT EXISTS idx_graph_nodes_properties ON graph_nodes USING gin(properties);
CREATE INDEX IF NOT EXISTS idx_graph_edges_properties ON graph_edges USING gin(properties);

-- Create metadata table
CREATE TABLE IF NOT EXISTS metadata (
    key VARCHAR(255) PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Insert schema version
INSERT INTO metadata (key, value) VALUES ('schema_version', '3.0.0')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
