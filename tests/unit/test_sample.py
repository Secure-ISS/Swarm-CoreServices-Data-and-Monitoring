"""Sample tests for pytest-quick hook validation."""


def test_passing():
    """A test that always passes."""
    assert 1 + 1 == 2


def test_passing_2():
    """Another passing test."""
    assert "hello".upper() == "HELLO"


def test_passing_3():
    """Yet another passing test."""
    numbers = [1, 2, 3, 4, 5]
    assert sum(numbers) == 15
