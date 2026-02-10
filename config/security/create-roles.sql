-- ============================================
-- PostgreSQL Role Creation and Privilege Assignment
-- ============================================
-- This script creates a secure role hierarchy for the distributed PostgreSQL cluster
-- Run as: psql -h pg-coordinator -U postgres -f create-roles.sql

-- ============================================
-- CLEANUP (Optional - comment out for production)
-- ============================================
-- DROP ROLE IF EXISTS cluster_admin;
-- DROP ROLE IF EXISTS replicator;
-- DROP ROLE IF EXISTS app_writer;
-- DROP ROLE IF EXISTS app_reader;
-- DROP ROLE IF EXISTS backup_agent;
-- DROP ROLE IF EXISTS monitor;
-- DROP ROLE IF EXISTS analytics_service;
-- DROP ROLE IF EXISTS api_service;

-- ============================================
-- 1. CLUSTER ADMINISTRATOR
-- ============================================
CREATE ROLE cluster_admin WITH
    LOGIN
    CREATEROLE
    CREATEDB
    REPLICATION
    BYPASSRLS
    PASSWORD NULL;  -- Certificate-based authentication

COMMENT ON ROLE cluster_admin IS 'Cluster administration and maintenance operations';

-- Grant all privileges on database
GRANT ALL PRIVILEGES ON DATABASE distributed_postgres_cluster TO cluster_admin;

-- ============================================
-- 2. REPLICATION USER
-- ============================================
CREATE ROLE replicator WITH
    LOGIN
    REPLICATION
    PASSWORD NULL;  -- Set via Docker secret

COMMENT ON ROLE replicator IS 'Physical/logical replication between nodes';

-- Grant minimal privileges
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO replicator;

-- ============================================
-- 3. APPLICATION WRITER (Read/Write)
-- ============================================
CREATE ROLE app_writer WITH
    LOGIN
    NOCREATEROLE
    NOCREATEDB
    NOREPLICATION
    PASSWORD NULL;  -- Set via application config

COMMENT ON ROLE app_writer IS 'Application read-write access to data tables';

-- Database-level privileges
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_writer;

-- Schema-level privileges
GRANT USAGE ON SCHEMA public TO app_writer;
GRANT USAGE ON SCHEMA claude_flow TO app_writer;

-- Table privileges (read/write on data tables)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA claude_flow TO app_writer;

-- Sequence privileges (for auto-increment columns)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA claude_flow TO app_writer;

-- Function privileges
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_writer;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA claude_flow TO app_writer;

-- Default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA claude_flow
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO app_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA claude_flow
    GRANT USAGE, SELECT ON SEQUENCES TO app_writer;

-- Prevent DDL operations
REVOKE CREATE ON SCHEMA public FROM app_writer;
REVOKE CREATE ON SCHEMA claude_flow FROM app_writer;

-- ============================================
-- 4. APPLICATION READER (Read-Only)
-- ============================================
CREATE ROLE app_reader WITH
    LOGIN
    NOCREATEROLE
    NOCREATEDB
    NOREPLICATION
    PASSWORD NULL;

COMMENT ON ROLE app_reader IS 'Application read-only access for reporting/analytics';

-- Database-level privileges
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO app_reader;

-- Schema-level privileges
GRANT USAGE ON SCHEMA public TO app_reader;
GRANT USAGE ON SCHEMA claude_flow TO app_reader;

-- Table privileges (read-only)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA claude_flow TO app_reader;

-- Default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO app_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA claude_flow
    GRANT SELECT ON TABLES TO app_reader;

-- Explicitly deny write operations
ALTER ROLE app_reader SET default_transaction_read_only = on;

-- ============================================
-- 5. BACKUP AGENT
-- ============================================
CREATE ROLE backup_agent WITH
    LOGIN
    REPLICATION  -- Needed for pg_basebackup
    NOCREATEROLE
    NOCREATEDB
    PASSWORD NULL;

COMMENT ON ROLE backup_agent IS 'Backup and restore operations';

-- Grant read access to all tables
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO backup_agent;
GRANT USAGE ON SCHEMA public, claude_flow TO backup_agent;
GRANT SELECT ON ALL TABLES IN SCHEMA public, claude_flow TO backup_agent;

-- Grant execute on backup-related functions
GRANT EXECUTE ON FUNCTION pg_start_backup(text, boolean, boolean) TO backup_agent;
GRANT EXECUTE ON FUNCTION pg_stop_backup(boolean, boolean) TO backup_agent;
GRANT EXECUTE ON FUNCTION pg_switch_wal() TO backup_agent;

-- ============================================
-- 6. MONITORING USER
-- ============================================
CREATE ROLE monitor WITH
    LOGIN
    NOCREATEROLE
    NOCREATEDB
    NOREPLICATION
    PASSWORD NULL;

COMMENT ON ROLE monitor IS 'Health monitoring and metrics collection';

-- Grant connection
GRANT CONNECT ON DATABASE distributed_postgres_cluster TO monitor;

-- Grant read access to system catalogs
GRANT USAGE ON SCHEMA pg_catalog TO monitor;
GRANT SELECT ON ALL TABLES IN SCHEMA pg_catalog TO monitor;

-- Grant access to statistics views
GRANT pg_monitor TO monitor;  -- Built-in role with monitoring privileges

-- Specific view privileges
GRANT SELECT ON pg_stat_database TO monitor;
GRANT SELECT ON pg_stat_activity TO monitor;
GRANT SELECT ON pg_stat_replication TO monitor;
GRANT SELECT ON pg_stat_ssl TO monitor;
GRANT SELECT ON pg_stat_statements TO monitor;
GRANT SELECT ON pg_stat_user_tables TO monitor;
GRANT SELECT ON pg_stat_user_indexes TO monitor;

-- ============================================
-- 7. SERVICE-SPECIFIC ROLES
-- ============================================

-- 7.1 Analytics Service (Read-Only + Aggregates)
CREATE ROLE analytics_service WITH LOGIN PASSWORD NULL;
COMMENT ON ROLE analytics_service IS 'Analytics and reporting service';

GRANT CONNECT ON DATABASE distributed_postgres_cluster TO analytics_service;
GRANT USAGE ON SCHEMA public, claude_flow TO analytics_service;
GRANT SELECT ON ALL TABLES IN SCHEMA public, claude_flow TO analytics_service;
ALTER ROLE analytics_service SET default_transaction_read_only = on;

-- 7.2 API Service (Limited Read/Write)
CREATE ROLE api_service WITH LOGIN PASSWORD NULL;
COMMENT ON ROLE api_service IS 'REST API service with limited access';

GRANT CONNECT ON DATABASE distributed_postgres_cluster TO api_service;
GRANT USAGE ON SCHEMA public, claude_flow TO api_service;

-- Grant access to specific tables only (example)
GRANT SELECT, INSERT, UPDATE ON TABLE public.api_data TO api_service;
GRANT SELECT ON TABLE public.reference_data TO api_service;

-- Grant execute on specific API functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO api_service;

-- ============================================
-- 8. SECURITY HARDENING
-- ============================================

-- Revoke public schema creation from PUBLIC
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Revoke all privileges from PUBLIC on new objects
ALTER DEFAULT PRIVILEGES REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE ALL ON FUNCTIONS FROM PUBLIC;

-- Prevent access to sensitive system tables
REVOKE ALL ON pg_authid FROM PUBLIC;
REVOKE ALL ON pg_shadow FROM PUBLIC;
REVOKE ALL ON pg_user_mapping FROM PUBLIC;

-- Disable dangerous functions for non-superusers
REVOKE EXECUTE ON FUNCTION pg_sleep(double precision) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_read_file(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_read_binary_file(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_ls_dir(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION pg_stat_file(text) FROM PUBLIC;

-- ============================================
-- 9. PASSWORD POLICIES (Install pgcrypto first)
-- ============================================

-- Ensure pgcrypto is installed
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Password strength check function
CREATE OR REPLACE FUNCTION check_password_strength(password TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    -- Minimum 16 characters
    IF LENGTH(password) < 16 THEN
        RAISE EXCEPTION 'Password must be at least 16 characters';
    END IF;

    -- Must contain uppercase
    IF password !~ '[A-Z]' THEN
        RAISE EXCEPTION 'Password must contain uppercase letters';
    END IF;

    -- Must contain lowercase
    IF password !~ '[a-z]' THEN
        RAISE EXCEPTION 'Password must contain lowercase letters';
    END IF;

    -- Must contain numbers
    IF password !~ '[0-9]' THEN
        RAISE EXCEPTION 'Password must contain numbers';
    END IF;

    -- Must contain special characters
    IF password !~ '[!@#$%^&*()_+=-]' THEN
        RAISE EXCEPTION 'Password must contain special characters';
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION check_password_strength(TEXT) IS 'Validates password meets complexity requirements';

-- ============================================
-- 10. AUDIT LOG SETUP
-- ============================================

-- Create audit log table
CREATE TABLE IF NOT EXISTS public.audit_log (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT now(),
    username TEXT,
    action TEXT,
    object_type TEXT,
    object_name TEXT,
    query TEXT,
    client_addr INET,
    success BOOLEAN,
    error_message TEXT
);

COMMENT ON TABLE public.audit_log IS 'Security audit trail for privileged operations';

-- Grant insert to all roles (for audit logging)
GRANT INSERT ON TABLE public.audit_log TO app_writer, app_reader, api_service;

-- Create audit function (triggered by DDL)
CREATE OR REPLACE FUNCTION audit_ddl_command()
RETURNS event_trigger AS $$
BEGIN
    INSERT INTO public.audit_log (username, action, query)
    VALUES (
        current_user,
        'DDL',
        current_query()
    );
END;
$$ LANGUAGE plpgsql;

-- Create event trigger (requires superuser)
-- CREATE EVENT TRIGGER audit_ddl_commands
--     ON ddl_command_end
--     EXECUTE FUNCTION audit_ddl_command();

-- ============================================
-- VERIFICATION QUERIES
-- ============================================

-- List all roles
SELECT
    rolname,
    rolsuper,
    rolcreaterole,
    rolcreatedb,
    rolcanlogin,
    rolreplication,
    rolbypassrls
FROM pg_roles
ORDER BY rolsuper DESC, rolname;

-- List role memberships
SELECT
    r.rolname AS role,
    m.rolname AS member
FROM pg_roles r
JOIN pg_auth_members am ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
ORDER BY r.rolname;

-- List database privileges
SELECT
    grantee,
    privilege_type
FROM information_schema.role_table_grants
WHERE table_schema IN ('public', 'claude_flow')
ORDER BY grantee, privilege_type;

-- ============================================
-- SUCCESS MESSAGE
-- ============================================
DO $$
BEGIN
    RAISE NOTICE 'Role creation complete!';
    RAISE NOTICE 'Total roles created: 8';
    RAISE NOTICE 'Next steps:';
    RAISE NOTICE '  1. Set passwords: ALTER USER app_writer WITH PASSWORD ''strong_password'';';
    RAISE NOTICE '  2. Update pg_hba.conf with authentication rules';
    RAISE NOTICE '  3. Reload configuration: SELECT pg_reload_conf();';
    RAISE NOTICE '  4. Test connections: psql -h pg-coordinator -U app_writer -d distributed_postgres_cluster';
END $$;
