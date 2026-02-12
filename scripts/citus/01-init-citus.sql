-- Citus Initialization SQL Script
-- Automatically run by docker-entrypoint-initdb.d
-- Creates extensions and basic configuration

-- Enable Citus extension
CREATE EXTENSION IF NOT EXISTS citus;

-- Enable RuVector extension for distributed vector operations
CREATE EXTENSION IF NOT EXISTS ruvector;

-- Enable useful PostgreSQL extensions
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create schemas for distributed data
CREATE SCHEMA IF NOT EXISTS distributed;
CREATE SCHEMA IF NOT EXISTS reference;
CREATE SCHEMA IF NOT EXISTS local;

-- Grant permissions
GRANT USAGE ON SCHEMA distributed TO PUBLIC;
GRANT USAGE ON SCHEMA reference TO PUBLIC;
GRANT USAGE ON SCHEMA local TO PUBLIC;

-- Configure pg_stat_statements
ALTER SYSTEM SET pg_stat_statements.max = 10000;
ALTER SYSTEM SET pg_stat_statements.track = 'all';

-- Log successful initialization
DO $$
BEGIN
    RAISE NOTICE 'Citus extensions initialized successfully';
    RAISE NOTICE 'Available extensions: citus, ruvector, pg_stat_statements, pgcrypto, uuid-ossp';
    RAISE NOTICE 'Created schemas: distributed, reference, local';
END $$;
