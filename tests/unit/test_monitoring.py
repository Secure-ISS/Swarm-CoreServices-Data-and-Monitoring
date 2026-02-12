#!/usr/bin/env python3
"""Unit tests for Database Index Monitoring and Query Optimization.

Tests IndexMonitor and PreparedStatementPool functionality including:
- Index usage monitoring
- Unused index detection
- Missing index identification
- Prepared statement pooling
- Query performance analysis
"""

# Standard library imports
import os
import sys
import unittest
from unittest.mock import MagicMock, Mock, patch

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

# Local imports
from src.db.monitoring import (
    COMMON_STATEMENTS,
    IndexMonitor,
    PreparedStatementPool,
    initialize_prepared_statements,
)


class TestIndexMonitor(unittest.TestCase):
    """Test IndexMonitor functionality."""

    def setUp(self):
        """Set up test fixtures."""
        self.mock_pool = MagicMock()
        self.mock_cursor = MagicMock()
        self.mock_pool.project_cursor.return_value.__enter__.return_value = self.mock_cursor
        self.monitor = IndexMonitor(self.mock_pool)

    def test_initialization(self):
        """Test IndexMonitor initialization."""
        self.assertEqual(self.monitor.pool, self.mock_pool)

    def test_get_unused_indexes_empty(self):
        """Test getting unused indexes when none exist."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("indexname",),
            ("scans",),
            ("size",),
            ("size_mb",),
        ]
        self.mock_cursor.fetchall.return_value = []

        result = self.monitor.get_unused_indexes()

        self.assertEqual(result, [])
        self.mock_cursor.execute.assert_called_once()

        # Verify query parameters
        call_args = self.mock_cursor.execute.call_args
        self.assertEqual(call_args[0][1], (1.0,))  # Default min_size_mb

    def test_get_unused_indexes_with_results(self):
        """Test getting unused indexes with results."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("indexname",),
            ("scans",),
            ("size",),
            ("size_mb",),
        ]

        unused_indexes = [
            ("public", "users", "idx_unused_email", 0, "5 MB", 5.0),
            ("public", "posts", "idx_unused_status", 0, "2 MB", 2.0),
        ]
        self.mock_cursor.fetchall.return_value = unused_indexes

        result = self.monitor.get_unused_indexes(min_size_mb=1.0)

        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["schemaname"], "public")
        self.assertEqual(result[0]["tablename"], "users")
        self.assertEqual(result[0]["indexname"], "idx_unused_email")
        self.assertEqual(result[0]["size_mb"], 5.0)

    def test_get_unused_indexes_custom_threshold(self):
        """Test getting unused indexes with custom size threshold."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("indexname",),
            ("scans",),
            ("size",),
            ("size_mb",),
        ]
        self.mock_cursor.fetchall.return_value = []

        self.monitor.get_unused_indexes(min_size_mb=10.0)

        call_args = self.mock_cursor.execute.call_args
        self.assertEqual(call_args[0][1], (10.0,))

    def test_get_missing_indexes_empty(self):
        """Test getting missing indexes when none detected."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("seq_scan",),
            ("seq_tup_read",),
            ("idx_scan",),
            ("seq_scan_pct",),
            ("size",),
        ]
        self.mock_cursor.fetchall.return_value = []

        result = self.monitor.get_missing_indexes()

        self.assertEqual(result, [])
        self.mock_cursor.execute.assert_called_once()

    def test_get_missing_indexes_with_results(self):
        """Test getting missing indexes with high sequential scans."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("seq_scan",),
            ("seq_tup_read",),
            ("idx_scan",),
            ("seq_scan_pct",),
            ("size",),
        ]

        high_seq_scan_tables = [
            ("public", "users", 5000, 500000, 100, 98.04, "10 MB"),
            ("public", "posts", 2500, 250000, 50, 98.00, "5 MB"),
        ]
        self.mock_cursor.fetchall.return_value = high_seq_scan_tables

        result = self.monitor.get_missing_indexes(min_seq_scans=1000)

        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["tablename"], "users")
        self.assertEqual(result[0]["seq_scan"], 5000)
        self.assertEqual(result[0]["seq_scan_pct"], 98.04)

    def test_get_missing_indexes_custom_threshold(self):
        """Test getting missing indexes with custom threshold."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("seq_scan",),
            ("seq_tup_read",),
            ("idx_scan",),
            ("seq_scan_pct",),
            ("size",),
        ]
        self.mock_cursor.fetchall.return_value = []

        self.monitor.get_missing_indexes(min_seq_scans=5000)

        call_args = self.mock_cursor.execute.call_args
        self.assertEqual(call_args[0][1], (5000,))

    def test_get_index_statistics(self):
        """Test getting overall index statistics."""
        # Setup mock cursor to return different results for each query
        total_stats_row = {"total_indexes": 50, "total_size_mb": 500.5}
        unused_stats_row = {"unused_count": 5, "unused_size_mb": 25.2}
        top_indexes = [
            {"indexname": "idx_users_email", "idx_scan": 10000},
            {"indexname": "idx_posts_created", "idx_scan": 8500},
            {"indexname": "idx_users_id", "idx_scan": 7200},
        ]

        self.mock_cursor.fetchone.side_effect = [total_stats_row, unused_stats_row]
        self.mock_cursor.fetchall.return_value = top_indexes

        result = self.monitor.get_index_statistics()

        self.assertEqual(result["total_indexes"], 50)
        self.assertEqual(result["total_size_mb"], 500.5)
        self.assertEqual(result["unused_count"], 5)
        self.assertEqual(result["unused_size_mb"], 25.2)
        self.assertEqual(result["unused_percentage"], 10.0)
        self.assertEqual(len(result["top_indexes"]), 3)
        self.assertEqual(result["top_indexes"][0]["name"], "idx_users_email")
        self.assertEqual(result["top_indexes"][0]["scans"], 10000)

    def test_get_index_statistics_no_indexes(self):
        """Test getting statistics when no indexes exist."""
        total_stats_row = {"total_indexes": 0, "total_size_mb": None}
        unused_stats_row = {"unused_count": 0, "unused_size_mb": None}

        self.mock_cursor.fetchone.side_effect = [total_stats_row, unused_stats_row]
        self.mock_cursor.fetchall.return_value = []

        result = self.monitor.get_index_statistics()

        self.assertEqual(result["total_indexes"], 0)
        self.assertEqual(result["total_size_mb"], 0.0)
        self.assertEqual(result["unused_count"], 0)
        self.assertEqual(result["unused_size_mb"], 0.0)
        self.assertEqual(result["unused_percentage"], 0.0)
        self.assertEqual(len(result["top_indexes"]), 0)

    def test_analyze_index_health_found(self):
        """Test analyzing health of existing index."""
        self.mock_cursor.description = [
            ("schemaname",),
            ("tablename",),
            ("indexname",),
            ("idx_scan",),
            ("idx_tup_read",),
            ("idx_tup_fetch",),
            ("size",),
        ]

        index_data = ("public", "users", "idx_users_email", 5000, 50000, 45000, "3 MB")
        self.mock_cursor.fetchone.return_value = index_data

        result = self.monitor.analyze_index_health("idx_users_email")

        self.assertEqual(result["schemaname"], "public")
        self.assertEqual(result["tablename"], "users")
        self.assertEqual(result["idx_scan"], 5000)
        self.assertEqual(result["size"], "3 MB")

        call_args = self.mock_cursor.execute.call_args
        self.assertEqual(call_args[0][1], ("idx_users_email",))

    def test_analyze_index_health_not_found(self):
        """Test analyzing health of non-existent index."""
        self.mock_cursor.fetchone.return_value = None

        result = self.monitor.analyze_index_health("idx_nonexistent")

        self.assertIn("error", result)
        self.assertIn("idx_nonexistent", result["error"])


class TestPreparedStatementPool(unittest.TestCase):
    """Test PreparedStatementPool functionality."""

    def setUp(self):
        """Set up test fixtures."""
        self.mock_pool = MagicMock()
        self.mock_cursor = MagicMock()
        self.mock_pool.project_cursor.return_value.__enter__.return_value = self.mock_cursor
        self.ps_pool = PreparedStatementPool(self.mock_pool)

    def test_initialization(self):
        """Test PreparedStatementPool initialization."""
        self.assertEqual(self.ps_pool.pool, self.mock_pool)
        self.assertEqual(len(self.ps_pool._prepared), 0)
        self.assertEqual(len(self.ps_pool._usage_stats), 0)

    def test_prepare_statement(self):
        """Test preparing a SQL statement."""
        sql = "SELECT * FROM users WHERE id = $1"

        self.ps_pool.prepare("get_user", sql)

        self.assertIn("get_user", self.ps_pool._prepared)
        self.assertEqual(self.ps_pool._prepared["get_user"], sql)
        self.assertEqual(self.ps_pool._usage_stats["get_user"], 0)

        # Verify PREPARE was executed
        self.mock_cursor.execute.assert_called_once()
        executed_sql = self.mock_cursor.execute.call_args[0][0]
        self.assertIn("PREPARE get_user AS", executed_sql)

    def test_prepare_statement_already_exists(self):
        """Test preparing a statement that already exists."""
        sql = "SELECT * FROM users WHERE id = $1"

        self.ps_pool.prepare("get_user", sql)
        self.mock_cursor.reset_mock()

        # Try to prepare again
        self.ps_pool.prepare("get_user", sql)

        # Should not execute PREPARE again
        self.mock_cursor.execute.assert_not_called()

    def test_execute_prepared_statement_with_params(self):
        """Test executing prepared statement with parameters."""
        sql = "SELECT * FROM users WHERE id = $1"
        self.ps_pool.prepare("get_user", sql)

        result_rows = [{"id": 123, "name": "John"}]
        self.mock_cursor.fetchall.return_value = result_rows

        result = self.ps_pool.execute("get_user", (123,))

        self.assertEqual(result, result_rows)
        self.assertEqual(self.ps_pool._usage_stats["get_user"], 1)

        # Verify EXECUTE was called with correct params
        executed_sql = self.mock_cursor.execute.call_args[0][0]
        self.assertIn("EXECUTE get_user", executed_sql)

    def test_execute_prepared_statement_no_params(self):
        """Test executing prepared statement without parameters."""
        sql = "SELECT COUNT(*) FROM users"
        self.ps_pool.prepare("count_users", sql)

        self.mock_cursor.fetchall.return_value = [{"count": 42}]

        result = self.ps_pool.execute("count_users")

        self.assertEqual(result, [{"count": 42}])
        self.assertEqual(self.ps_pool._usage_stats["count_users"], 1)

    def test_execute_statement_not_prepared(self):
        """Test executing statement that was not prepared."""
        with self.assertRaises(ValueError) as context:
            self.ps_pool.execute("nonexistent")

        self.assertIn("not prepared", str(context.exception))
        self.assertIn("nonexistent", str(context.exception))

    def test_execute_statement_no_results(self):
        """Test executing statement that returns no results (INSERT/UPDATE)."""
        sql = "UPDATE users SET name = $1 WHERE id = $2"
        self.ps_pool.prepare("update_user", sql)

        # fetchall() raises exception for non-SELECT queries
        self.mock_cursor.fetchall.side_effect = Exception("No results")

        result = self.ps_pool.execute("update_user", ("Jane", 123))

        # Should return empty list on exception
        self.assertEqual(result, [])
        self.assertEqual(self.ps_pool._usage_stats["update_user"], 1)

    def test_get_stats(self):
        """Test getting usage statistics."""
        # Prepare and execute multiple statements
        self.ps_pool.prepare("stmt1", "SELECT 1")
        self.ps_pool.prepare("stmt2", "SELECT 2")

        self.mock_cursor.fetchall.return_value = []

        self.ps_pool.execute("stmt1")
        self.ps_pool.execute("stmt1")
        self.ps_pool.execute("stmt2")

        stats = self.ps_pool.get_stats()

        self.assertEqual(stats["stmt1"], 2)
        self.assertEqual(stats["stmt2"], 1)
        self.assertEqual(len(stats), 2)

    def test_get_stats_empty(self):
        """Test getting statistics when no statements executed."""
        stats = self.ps_pool.get_stats()

        self.assertEqual(stats, {})

    def test_deallocate_statement(self):
        """Test deallocating a prepared statement."""
        sql = "SELECT * FROM users WHERE id = $1"
        self.ps_pool.prepare("get_user", sql)

        self.assertIn("get_user", self.ps_pool._prepared)
        self.mock_cursor.reset_mock()

        self.ps_pool.deallocate("get_user")

        self.assertNotIn("get_user", self.ps_pool._prepared)
        self.assertNotIn("get_user", self.ps_pool._usage_stats)

        # Verify DEALLOCATE was executed
        self.mock_cursor.execute.assert_called_once()
        executed_sql = self.mock_cursor.execute.call_args[0][0]
        self.assertIn("DEALLOCATE get_user", executed_sql)

    def test_deallocate_nonexistent_statement(self):
        """Test deallocating a statement that doesn't exist."""
        # Should not raise exception
        self.ps_pool.deallocate("nonexistent")

        # Should not execute anything
        self.mock_cursor.execute.assert_not_called()

    def test_multiple_executions_increment_stats(self):
        """Test that multiple executions increment usage stats correctly."""
        sql = "SELECT * FROM users WHERE id = $1"
        self.ps_pool.prepare("get_user", sql)
        self.mock_cursor.fetchall.return_value = []

        # Execute 5 times
        for i in range(5):
            self.ps_pool.execute("get_user", (i,))

        stats = self.ps_pool.get_stats()
        self.assertEqual(stats["get_user"], 5)


class TestInitializePreparedStatements(unittest.TestCase):
    """Test initialize_prepared_statements function."""

    def test_initialize_all_statements(self):
        """Test initializing all common statements."""
        mock_pool = MagicMock()
        mock_cursor = MagicMock()
        mock_pool.project_cursor.return_value.__enter__.return_value = mock_cursor

        ps_pool = initialize_prepared_statements(mock_pool)

        # Should have prepared all common statements
        self.assertEqual(len(ps_pool._prepared), len(COMMON_STATEMENTS))

        for name in COMMON_STATEMENTS.keys():
            self.assertIn(name, ps_pool._prepared)
            self.assertEqual(ps_pool._usage_stats[name], 0)

    def test_initialize_with_failure(self):
        """Test initialization when some statements fail."""
        mock_pool = MagicMock()
        mock_cursor = MagicMock()
        mock_pool.project_cursor.return_value.__enter__.return_value = mock_cursor

        # Make first statement fail
        mock_cursor.execute.side_effect = [Exception("Parse error")] + [None] * (
            len(COMMON_STATEMENTS) - 1
        )

        ps_pool = initialize_prepared_statements(mock_pool)

        # Should continue despite failure
        self.assertIsNotNone(ps_pool)
        # Will have fewer prepared statements due to failure
        self.assertLess(len(ps_pool._prepared), len(COMMON_STATEMENTS))


class TestCommonStatements(unittest.TestCase):
    """Test COMMON_STATEMENTS definitions."""

    def test_common_statements_defined(self):
        """Test that common statements are defined."""
        self.assertGreater(len(COMMON_STATEMENTS), 0)

    def test_vector_search_statement(self):
        """Test vector search statement is defined."""
        self.assertIn("vector_search_namespace", COMMON_STATEMENTS)
        sql = COMMON_STATEMENTS["vector_search_namespace"]
        self.assertIn("ruvector", sql)
        self.assertIn("distance", sql)

    def test_insert_memory_statement(self):
        """Test insert memory statement is defined."""
        self.assertIn("insert_memory_entry", COMMON_STATEMENTS)
        sql = COMMON_STATEMENTS["insert_memory_entry"]
        self.assertIn("INSERT INTO memory_entries", sql)
        self.assertIn("ON CONFLICT", sql)

    def test_pattern_statements(self):
        """Test pattern-related statements are defined."""
        self.assertIn("get_pattern_by_id", COMMON_STATEMENTS)
        self.assertIn("list_patterns_by_type", COMMON_STATEMENTS)

    def test_all_statements_have_sql(self):
        """Test that all statements contain SQL."""
        for name, sql in COMMON_STATEMENTS.items():
            self.assertIsInstance(sql, str)
            self.assertGreater(len(sql), 0)
            # Should contain some SQL keyword
            self.assertTrue(
                any(keyword in sql.upper() for keyword in ["SELECT", "INSERT", "UPDATE"])
            )


if __name__ == "__main__":
    unittest.main()
