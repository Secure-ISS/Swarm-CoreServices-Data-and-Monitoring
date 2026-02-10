-- ============================================
-- ROLE-BASED ACCESS CONTROL (RBAC) POLICIES
-- ============================================
-- Fine-grained access control for distributed PostgreSQL cluster
-- Run after create-roles.sql

-- ============================================
-- 1. SCHEMA-LEVEL ISOLATION
-- ============================================

-- Create tenant-specific schemas
CREATE SCHEMA IF NOT EXISTS tenant_a;
CREATE SCHEMA IF NOT EXISTS tenant_b;
CREATE SCHEMA IF NOT EXISTS tenant_c;

COMMENT ON SCHEMA tenant_a IS 'Tenant A isolated data';
COMMENT ON SCHEMA tenant_b IS 'Tenant B isolated data';
COMMENT ON SCHEMA tenant_c IS 'Tenant C isolated data';

-- Create tenant-specific roles
CREATE ROLE tenant_a_user WITH LOGIN;
CREATE ROLE tenant_b_user WITH LOGIN;
CREATE ROLE tenant_c_user WITH LOGIN;

-- Grant schema access only to respective tenant
GRANT USAGE ON SCHEMA tenant_a TO tenant_a_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA tenant_a TO tenant_a_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA tenant_a TO tenant_a_user;

GRANT USAGE ON SCHEMA tenant_b TO tenant_b_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA tenant_b TO tenant_b_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA tenant_b TO tenant_b_user;

GRANT USAGE ON SCHEMA tenant_c TO tenant_c_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA tenant_c TO tenant_c_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA tenant_c TO tenant_c_user;

-- Deny cross-tenant access
REVOKE ALL ON SCHEMA tenant_a FROM tenant_b_user, tenant_c_user;
REVOKE ALL ON SCHEMA tenant_b FROM tenant_a_user, tenant_c_user;
REVOKE ALL ON SCHEMA tenant_c FROM tenant_a_user, tenant_b_user;

-- ============================================
-- 2. TABLE-LEVEL GRANULAR PERMISSIONS
-- ============================================

-- Example: Restrict app_writer to specific operations
-- Assume tables: users, transactions, sensitive_data

-- Users table: full CRUD access
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.users TO app_writer;

-- Transactions table: read and insert only (no updates/deletes)
GRANT SELECT, INSERT ON TABLE public.transactions TO app_writer;
REVOKE UPDATE, DELETE ON TABLE public.transactions FROM app_writer;

-- Sensitive data: read-only for app_writer
GRANT SELECT ON TABLE public.sensitive_data TO app_writer;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.sensitive_data FROM app_writer;

-- ============================================
-- 3. COLUMN-LEVEL SECURITY
-- ============================================

-- Example: Hide sensitive columns from app_reader
-- Assume users table has columns: id, username, email, ssn, salary

-- Grant column-level SELECT (exclude SSN and salary)
GRANT SELECT (id, username, email) ON TABLE public.users TO app_reader;

-- app_writer gets full column access
GRANT SELECT, UPDATE (id, username, email, ssn, salary) ON TABLE public.users TO app_writer;

-- ============================================
-- 4. FUNCTION-LEVEL ACCESS CONTROL
-- ============================================

-- Revoke public execute on sensitive functions
REVOKE EXECUTE ON FUNCTION delete_user(INT) FROM PUBLIC;

-- Grant execute only to cluster_admin
GRANT EXECUTE ON FUNCTION delete_user(INT) TO cluster_admin;

-- Example: Create security definer function for privilege elevation
CREATE OR REPLACE FUNCTION secure_delete_old_logs()
RETURNS void AS $$
BEGIN
    DELETE FROM logs WHERE created_at < now() - INTERVAL '90 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute to app_writer (runs with definer's privileges)
GRANT EXECUTE ON FUNCTION secure_delete_old_logs() TO app_writer;

-- ============================================
-- 5. ROW-LEVEL SECURITY (RLS) SETUP
-- ============================================

-- Enable RLS on multi-tenant tables
ALTER TABLE public.user_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_data ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only see their own data
CREATE POLICY user_isolation_policy ON public.user_data
    FOR ALL
    TO app_writer, app_reader
    USING (user_id = current_user::int);

-- Policy: Tenant isolation (requires application to set tenant context)
CREATE POLICY tenant_isolation_policy ON public.tenant_data
    FOR ALL
    TO app_writer, app_reader
    USING (tenant_id = current_setting('app.current_tenant_id', true)::int);

-- Policy: Time-based access (business hours only)
CREATE POLICY business_hours_policy ON public.sensitive_operations
    FOR ALL
    TO app_writer
    USING (
        EXTRACT(HOUR FROM now()) BETWEEN 8 AND 18 AND
        EXTRACT(DOW FROM now()) BETWEEN 1 AND 5  -- Monday to Friday
    );

-- Policy: Admin bypass (cluster_admin can see everything)
CREATE POLICY admin_full_access ON public.user_data
    FOR ALL
    TO cluster_admin
    USING (true)
    WITH CHECK (true);

CREATE POLICY admin_tenant_access ON public.tenant_data
    FOR ALL
    TO cluster_admin
    USING (true)
    WITH CHECK (true);

-- ============================================
-- 6. PREVENT PRIVILEGE ESCALATION
-- ============================================

-- Disable CREATE ROLE for non-admins
REVOKE CREATE ROLE ON DATABASE distributed_postgres_cluster FROM PUBLIC;

-- Disable CREATE DATABASE for non-admins
REVOKE CREATE DATABASE ON DATABASE distributed_postgres_cluster FROM PUBLIC;

-- Disable ALTER SYSTEM for non-superusers (already default)
-- Only postgres superuser can run ALTER SYSTEM

-- Prevent bypassing RLS
REVOKE BYPASSRLS FROM app_writer, app_reader, api_service;

-- ============================================
-- 7. AUDIT PRIVILEGED OPERATIONS
-- ============================================

-- Create trigger to log GRANT/REVOKE operations
CREATE OR REPLACE FUNCTION audit_privilege_changes()
RETURNS event_trigger AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF obj.command_tag IN ('GRANT', 'REVOKE') THEN
            INSERT INTO public.audit_log (username, action, object_type, object_name, query)
            VALUES (
                current_user,
                obj.command_tag,
                obj.object_type,
                obj.object_identity,
                current_query()
            );
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Create event trigger (requires superuser)
-- DROP EVENT TRIGGER IF EXISTS audit_privilege_changes_trigger;
-- CREATE EVENT TRIGGER audit_privilege_changes_trigger
--     ON ddl_command_end
--     WHEN TAG IN ('GRANT', 'REVOKE')
--     EXECUTE FUNCTION audit_privilege_changes();

-- ============================================
-- 8. ROLE MEMBERSHIP HIERARCHY
-- ============================================

-- Create role groups
CREATE ROLE read_only_group;
CREATE ROLE read_write_group;
CREATE ROLE admin_group;

-- Grant base privileges to groups
GRANT SELECT ON ALL TABLES IN SCHEMA public TO read_only_group;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO read_write_group;
GRANT ALL PRIVILEGES ON SCHEMA public TO admin_group;

-- Assign users to groups
GRANT read_only_group TO app_reader, analytics_service;
GRANT read_write_group TO app_writer, api_service;
GRANT admin_group TO cluster_admin;

-- ============================================
-- 9. CONNECTION LIMITS
-- ============================================

-- Set connection limits per role
ALTER ROLE app_writer CONNECTION LIMIT 100;
ALTER ROLE app_reader CONNECTION LIMIT 50;
ALTER ROLE analytics_service CONNECTION LIMIT 20;
ALTER ROLE monitor CONNECTION LIMIT 5;

-- ============================================
-- 10. SESSION SECURITY SETTINGS
-- ============================================

-- Force SSL for specific roles
ALTER ROLE app_writer SET ssl TO on;
ALTER ROLE app_reader SET ssl TO on;

-- Set statement timeout (prevent long-running queries)
ALTER ROLE app_writer SET statement_timeout = '300s';  -- 5 minutes
ALTER ROLE app_reader SET statement_timeout = '600s';  -- 10 minutes
ALTER ROLE analytics_service SET statement_timeout = '3600s';  -- 1 hour

-- Set idle timeout
ALTER ROLE app_writer SET idle_in_transaction_session_timeout = '600s';  -- 10 minutes
ALTER ROLE app_reader SET idle_in_transaction_session_timeout = '600s';

-- Force read-only mode for specific roles
ALTER ROLE app_reader SET default_transaction_read_only = on;
ALTER ROLE analytics_service SET default_transaction_read_only = on;

-- Restrict search path (prevent schema injection)
ALTER ROLE app_writer SET search_path = public, claude_flow;
ALTER ROLE app_reader SET search_path = public, claude_flow;

-- ============================================
-- 11. OBJECT OWNERSHIP CONTROL
-- ============================================

-- Set default owner for new objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO read_only_group;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO read_write_group;

-- Prevent object creation by app roles
REVOKE CREATE ON SCHEMA public FROM app_writer, app_reader;

-- ============================================
-- 12. VIEW-BASED ACCESS CONTROL
-- ============================================

-- Create restricted view (hide sensitive columns)
CREATE OR REPLACE VIEW public.users_public AS
SELECT
    id,
    username,
    email,
    created_at
FROM public.users;
-- Exclude: ssn, salary, password_hash

-- Grant view access to app_reader
GRANT SELECT ON public.users_public TO app_reader;

-- Deny direct table access
REVOKE SELECT ON public.users FROM app_reader;

-- ============================================
-- VERIFICATION QUERIES
-- ============================================

-- Check RLS policies
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies
ORDER BY schemaname, tablename;

-- Check table privileges
SELECT
    grantee,
    table_schema,
    table_name,
    privilege_type
FROM information_schema.table_privileges
WHERE table_schema IN ('public', 'claude_flow', 'tenant_a', 'tenant_b', 'tenant_c')
ORDER BY grantee, table_schema, table_name;

-- Check column privileges
SELECT
    grantee,
    table_schema,
    table_name,
    column_name,
    privilege_type
FROM information_schema.column_privileges
WHERE table_schema = 'public'
ORDER BY grantee, table_name, column_name;

-- Check role memberships
SELECT
    r.rolname AS role,
    m.rolname AS member
FROM pg_roles r
JOIN pg_auth_members am ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
ORDER BY r.rolname;

-- Check role connection limits
SELECT
    rolname,
    rolconnlimit
FROM pg_roles
WHERE rolconnlimit != -1
ORDER BY rolname;

-- ============================================
-- SUCCESS MESSAGE
-- ============================================
DO $$
BEGIN
    RAISE NOTICE 'RBAC policies configured successfully!';
    RAISE NOTICE 'Security enhancements:';
    RAISE NOTICE '  - Schema-level isolation (multi-tenant)';
    RAISE NOTICE '  - Table/column-level permissions';
    RAISE NOTICE '  - Row-level security (RLS)';
    RAISE NOTICE '  - Connection limits';
    RAISE NOTICE '  - Session security settings';
    RAISE NOTICE 'Next steps:';
    RAISE NOTICE '  1. Test RLS: SET app.current_tenant_id = 1; SELECT * FROM tenant_data;';
    RAISE NOTICE '  2. Verify policies: SELECT * FROM pg_policies;';
    RAISE NOTICE '  3. Test role permissions with psql -U <role>';
END $$;
