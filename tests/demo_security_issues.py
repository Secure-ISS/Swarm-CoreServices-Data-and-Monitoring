"""Demonstration file with security issues for hook testing."""

# Standard library imports
import pickle
import subprocess

# Hardcoded secrets
API_KEY = "sk_test_FAKE_KEY_FOR_DEMO_ONLY"
AWS_ACCESS_KEY = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
PASSWORD = "SuperSecret123!"


# SQL injection vulnerability
def unsafe_query(user_input):
    """Execute unsafe SQL query."""
    query = f"SELECT * FROM users WHERE name = '{user_input}'"
    cursor.execute(query)
    return cursor.fetchall()


# Command injection
def unsafe_command(user_input):
    """Execute unsafe shell command."""
    return subprocess.call(f"ls {user_input}", shell=True)


# Unsafe deserialization
def unsafe_pickle(data):
    """Deserialize untrusted data."""
    return pickle.loads(data)


# Another SQL injection pattern
def another_unsafe_query(user_id):
    """Execute unsafe SQL query with concatenation."""
    query = "SELECT * FROM users WHERE id = " + str(user_id)
    cursor.execute(query)
    return cursor.fetchone()
