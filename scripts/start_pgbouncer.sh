#!/bin/bash
# Start PgBouncer for distributed PostgreSQL cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"
LOG_DIR="/var/log/pgbouncer"
RUN_DIR="/var/run/pgbouncer"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Starting PgBouncer ===${NC}"

# Check if PgBouncer is installed
if ! command -v pgbouncer &> /dev/null; then
    echo -e "${RED}✗ PgBouncer is not installed${NC}"
    echo ""
    echo "Install PgBouncer:"
    echo "  Ubuntu/Debian: sudo apt-get install pgbouncer"
    echo "  CentOS/RHEL:   sudo yum install pgbouncer"
    echo "  macOS:         brew install pgbouncer"
    exit 1
fi

echo -e "${GREEN}✓ PgBouncer is installed${NC}"

# Check if config file exists
if [ ! -f "$CONFIG_DIR/pgbouncer.ini" ]; then
    echo -e "${RED}✗ Config file not found: $CONFIG_DIR/pgbouncer.ini${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Config file found${NC}"

# Create log directory if it doesn't exist
if [ ! -d "$LOG_DIR" ]; then
    echo -e "${YELLOW}Creating log directory: $LOG_DIR${NC}"
    sudo mkdir -p "$LOG_DIR"
    sudo chown $USER:$USER "$LOG_DIR"
fi

# Create run directory if it doesn't exist
if [ ! -d "$RUN_DIR" ]; then
    echo -e "${YELLOW}Creating run directory: $RUN_DIR${NC}"
    sudo mkdir -p "$RUN_DIR"
    sudo chown $USER:$USER "$RUN_DIR"
fi

# Check if PgBouncer is already running
if [ -f "$RUN_DIR/pgbouncer.pid" ]; then
    PID=$(cat "$RUN_DIR/pgbouncer.pid")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo -e "${YELLOW}PgBouncer is already running (PID: $PID)${NC}"
        echo ""
        echo "To stop PgBouncer:"
        echo "  pkill -F $RUN_DIR/pgbouncer.pid"
        echo ""
        echo "To reload config:"
        echo "  psql -h localhost -p 6432 -U postgres pgbouncer -c 'RELOAD;'"
        exit 0
    else
        echo -e "${YELLOW}Removing stale PID file${NC}"
        rm -f "$RUN_DIR/pgbouncer.pid"
    fi
fi

# Generate MD5 passwords for userlist.txt
echo -e "${YELLOW}Generating password hashes for userlist.txt${NC}"

# Create userlist.txt with MD5 hashed passwords
cat > "$CONFIG_DIR/userlist.txt" <<EOF
;; PgBouncer userlist.txt
;; Auto-generated on $(date)
;; Format: "username" "md5<hash>"

EOF

# Function to generate MD5 hash for PostgreSQL
generate_md5() {
    local password="$1"
    local username="$2"
    echo -n "${password}${username}" | md5sum | awk '{print "md5" $1}'
}

# Add users from .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"

    if [ -n "$COORDINATOR_USER" ] && [ -n "$COORDINATOR_PASSWORD" ]; then
        HASH=$(generate_md5 "$COORDINATOR_PASSWORD" "$COORDINATOR_USER")
        echo "\"$COORDINATOR_USER\" \"$HASH\"" >> "$CONFIG_DIR/userlist.txt"
        echo -e "${GREEN}✓ Added user: $COORDINATOR_USER${NC}"
    fi

    if [ -n "$SHARED_KNOWLEDGE_USER" ] && [ -n "$SHARED_KNOWLEDGE_PASSWORD" ]; then
        HASH=$(generate_md5 "$SHARED_KNOWLEDGE_PASSWORD" "$SHARED_KNOWLEDGE_USER")
        echo "\"$SHARED_KNOWLEDGE_USER\" \"$HASH\"" >> "$CONFIG_DIR/userlist.txt"
        echo -e "${GREEN}✓ Added user: $SHARED_KNOWLEDGE_USER${NC}"
    fi
fi

# Add postgres user (for admin console)
POSTGRES_HASH=$(generate_md5 "postgres" "postgres")
echo "\"postgres\" \"$POSTGRES_HASH\"" >> "$CONFIG_DIR/userlist.txt"
echo -e "${GREEN}✓ Added user: postgres${NC}"

# Start PgBouncer
echo ""
echo -e "${GREEN}Starting PgBouncer...${NC}"

pgbouncer -d "$CONFIG_DIR/pgbouncer.ini"

# Wait for PgBouncer to start
sleep 2

# Check if PgBouncer started successfully
if [ -f "$RUN_DIR/pgbouncer.pid" ]; then
    PID=$(cat "$RUN_DIR/pgbouncer.pid")
    if ps -p "$PID" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PgBouncer started successfully (PID: $PID)${NC}"
        echo ""
        echo "PgBouncer is listening on:"
        echo "  Host: localhost"
        echo "  Port: 6432"
        echo ""
        echo "Connect to database:"
        echo "  psql -h localhost -p 6432 -U dpg_cluster distributed_postgres_cluster"
        echo ""
        echo "Admin console:"
        echo "  psql -h localhost -p 6432 -U postgres pgbouncer"
        echo ""
        echo "View statistics:"
        echo "  psql -h localhost -p 6432 -U postgres pgbouncer -c 'SHOW POOLS;'"
        echo "  psql -h localhost -p 6432 -U postgres pgbouncer -c 'SHOW STATS;'"
        echo ""
        echo "Reload configuration:"
        echo "  psql -h localhost -p 6432 -U postgres pgbouncer -c 'RELOAD;'"
        echo ""
        echo "Stop PgBouncer:"
        echo "  pkill -F $RUN_DIR/pgbouncer.pid"
        echo ""
        echo "Log file: $LOG_DIR/pgbouncer.log"
    else
        echo -e "${RED}✗ PgBouncer failed to start${NC}"
        echo "Check log file: $LOG_DIR/pgbouncer.log"
        exit 1
    fi
else
    echo -e "${RED}✗ PgBouncer PID file not found${NC}"
    echo "Check log file: $LOG_DIR/pgbouncer.log"
    exit 1
fi
