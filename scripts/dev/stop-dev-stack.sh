#!/bin/bash
# Stop Development Stack

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=================================================="
echo "Stopping Development Stack"
echo "=================================================="

cd "$PROJECT_ROOT"

# Stop the stack
docker compose -f docker-compose.dev.yml down

echo ""
echo "Development stack stopped."
echo ""
echo "To remove volumes (clean slate): docker compose -f docker-compose.dev.yml down -v"
