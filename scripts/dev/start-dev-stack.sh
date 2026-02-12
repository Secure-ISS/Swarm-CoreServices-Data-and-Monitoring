#!/bin/bash
# Start Development Stack - 2GB Memory Budget
# Single unified stack for local development

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=================================================="
echo "Starting Development Stack (2GB Memory Budget)"
echo "=================================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running${NC}"
    exit 1
fi

# Stop old containers (clean start)
echo -e "${YELLOW}Stopping old containers...${NC}"
docker stop ruvector-db redis-cache 2>/dev/null || true
docker ps -a --format "{{.Names}}" | grep -E "crazy_|dreamy_|pensive_|peaceful_|bold_|elated_|busy_|intelligent_|funny_|vigilant_|lucid_|reverent_|xenodochial_|laughing_|tender_|charming_|youthful_|angry_" | xargs -r docker stop 2>/dev/null || true

echo -e "${YELLOW}Removing old containers...${NC}"
docker ps -a --format "{{.Names}}" | grep -E "crazy_|dreamy_|pensive_|peaceful_|bold_|elated_|busy_|intelligent_|funny_|vigilant_|lucid_|reverent_|xenodochial_|laughing_|tender_|charming_|youthful_|angry_" | xargs -r docker rm 2>/dev/null || true

# Change to project root
cd "$PROJECT_ROOT"

# Check if .env exists
if [ ! -f .env ]; then
    echo -e "${YELLOW}Creating .env file from .env.example...${NC}"
    cp .env.example .env
fi

# Start the development stack
echo -e "${GREEN}Starting development stack...${NC}"
docker compose -f docker-compose.dev.yml up -d

# Wait for services to be healthy
echo ""
echo -e "${YELLOW}Waiting for services to be healthy...${NC}"
sleep 5

# Check PostgreSQL
echo -n "  Checking PostgreSQL... "
for i in {1..30}; do
    if docker exec dpg-postgres-dev pg_isready -U dpg_cluster > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}FAILED${NC}"
        exit 1
    fi
    sleep 1
done

# Check Redis
echo -n "  Checking Redis... "
for i in {1..30}; do
    if docker exec dpg-redis-dev redis-cli ping > /dev/null 2>&1; then
        echo -e "${GREEN}OK${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}FAILED${NC}"
        exit 1
    fi
    sleep 1
done

# Display status
echo ""
echo "=================================================="
echo -e "${GREEN}Development Stack Started Successfully!${NC}"
echo "=================================================="
echo ""
echo "Services:"
echo "  PostgreSQL: localhost:5432"
echo "  Redis:      localhost:6379"
echo ""
echo "Memory Allocation:"
echo "  PostgreSQL: 1.2GB (limit) / 800MB (reserved)"
echo "  Redis:      256MB (limit) / 128MB (reserved)"
echo "  Total:      ~1.5GB (allowing 500MB for OS/app)"
echo ""
echo "Database Credentials:"
echo "  User:     dpg_cluster"
echo "  Password: dpg_cluster_2026"
echo "  Database: distributed_postgres_cluster"
echo ""
echo "Management:"
echo "  View logs:    docker compose -f docker-compose.dev.yml logs -f"
echo "  Stop stack:   docker compose -f docker-compose.dev.yml down"
echo "  Restart:      docker compose -f docker-compose.dev.yml restart"
echo "  Clean volumes: docker compose -f docker-compose.dev.yml down -v"
echo ""
echo "Optional PgAdmin (adds 256MB):"
echo "  Start: docker compose -f docker-compose.dev.yml --profile tools up -d pgadmin"
echo "  URL:   http://localhost:8080"
echo ""
echo -e "${GREEN}Ready for development!${NC}"
