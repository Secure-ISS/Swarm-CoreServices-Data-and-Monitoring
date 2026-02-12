"""Demonstration file with bad formatting for hook testing."""

# Bad imports - unsorted and mixed
# Standard library imports
import asyncio
import json
import os
import sys
from typing import Dict, List


# Bad formatting
def bad_function(x, y, z):
    return x + y + z


class BadClass:
    def __init__(self, name, age):
        self.name = name
        self.age = age


# Long line that exceeds limit
def really_long_function_name_that_should_be_wrapped(
    parameter1, parameter2, parameter3, parameter4, parameter5, parameter6
):
    return parameter1 + parameter2 + parameter3 + parameter4 + parameter5 + parameter6
