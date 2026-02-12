#!/usr/bin/env bash
#
# stack-manager.sh - Unified Stack Management for Distributed PostgreSQL Cluster
#
# Description:
#   Production-ready stack management script to easily switch between deployment modes.
#   Supports dev, citus, patroni, monitoring, and production stacks with comprehensive
#   error handling, logging, and interactive mode.
#
# Usage:
#   ./stack-manager.sh start <mode>       - Start a stack
#   ./stack-manager.sh stop <mode>        - Stop a stack
#   ./stack-manager.sh restart <mode>     - Restart a stack
#   ./stack-manager.sh status             - Show status of all stacks
#   ./stack-manager.sh logs <mode>        - Show logs for a stack
#   ./stack-manager.sh clean <mode>       - Stop and remove volumes
#   ./stack-manager.sh interactive        - Interactive menu mode
#
# Modes:
#   dev          - Simple 4GB development stack (Postgres + Redis + PgAdmin)
#   citus        - Distributed sharding cluster (1 coordinator + 3 workers)
#   patroni      - High-availability cluster (3-node + etcd + HAProxy)
#   monitoring   - Observability stack (Prometheus + Grafana + exporters)
#   production   - Full production stack (all components)
#
# Author: Claude Code
# Date: 2026-02-12
# Version: 1.0.0
#

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/stack-manager.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Stack definitions
declare -A STACK_COMPOSE_FILES=(
    ["dev"]="${PROJECT_ROOT}/docker-compose.dev.yml"
    ["citus"]="${PROJECT_ROOT}/docker/citus/docker-compose.yml"
    ["patroni"]="${PROJECT_ROOT}/docker/patroni/docker-compose.yml"
    ["monitoring"]="${PROJECT_ROOT}/docker/monitoring/docker-compose.yml"
    ["production"]="${PROJECT_ROOT}/docker/production/docker-compose.yml"
)

declare -A STACK_DESCRIPTIONS=(
    ["dev"]="Simple 4GB development stack (Postgres + Redis + PgAdmin)"
    ["citus"]="Distributed sharding cluster (1 coordinator + 3 workers)"
    ["patroni"]="High-availability cluster (3-node + etcd + HAProxy)"
    ["monitoring"]="Observability stack (Prometheus + Grafana + exporters)"
    ["production"]="Full production stack (all components)"
)

declare -A STACK_PORTS=(
    ["dev"]="5432:PostgreSQL, 6379:Redis, 8080:PgAdmin"
    ["citus"]="5432:Coordinator, 5433-5435:Workers, 6379:Redis, 8080:PgAdmin"
    ["patroni"]="5000:Primary, 5001:Replicas, 7000:HAProxy Stats, 8008-8010:Patroni APIs"
    ["monitoring"]="9090:Prometheus, 3000:Grafana, 9093:AlertManager, 9187:Postgres Exporter"
    ["production"]="5432:HAProxy-RW, 5433:HAProxy-RO, 6432:PgBouncer, 9090:Prometheus, 3001:Grafana"
)

declare -A STACK_URLS=(
    ["dev"]="http://localhost:8080 (PgAdmin)"
    ["citus"]="http://localhost:8080 (PgAdmin)"
    ["patroni"]="http://localhost:7000 (HAProxy Stats)"
    ["monitoring"]="http://localhost:3000 (Grafana), http://localhost:9090 (Prometheus)"
    ["production"]="http://localhost:3001 (Grafana), http://localhost:9090 (Prometheus)"
)

# Conflicting ports between stacks
declare -A PORT_CONFLICTS=(
    ["5432"]="dev,citus,patroni,production"
    ["6379"]="dev,citus"
    ["8080"]="dev,citus"
    ["9090"]="monitoring,production"
)

# ============================================================
# Logging Functions
# ============================================================

setup_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}✓${NC} $*"
}

log_warning() {
    log "WARNING" "$@"
    echo -e "${YELLOW}⚠${NC} $*"
}

log_error() {
    log "ERROR" "$@"
    echo -e "${RED}✗${NC} $*" >&2
}

log_step() {
    log "STEP" "$@"
    echo -e "${CYAN}→${NC} $*"
}

# ============================================================
# Validation Functions
# ============================================================

check_dependencies() {
    local missing=()

    if ! command -v docker &> /dev/null; then
        missing+=("docker")
    fi

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        missing+=("docker-compose")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them before running this script."
        return 1
    fi

    return 0
}

validate_mode() {
    local mode="$1"

    if [[ ! ${STACK_COMPOSE_FILES[$mode]+_} ]]; then
        log_error "Invalid mode: $mode"
        log_error "Valid modes: ${!STACK_COMPOSE_FILES[*]}"
        return 1
    fi

    if [[ ! -f "${STACK_COMPOSE_FILES[$mode]}" ]]; then
        log_error "Compose file not found: ${STACK_COMPOSE_FILES[$mode]}"
        return 1
    fi

    return 0
}

check_docker_running() {
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        return 1
    fi
    return 0
}

# ============================================================
# Port Management Functions
# ============================================================

get_port_usage() {
    local port="$1"
    if command -v lsof &> /dev/null; then
        lsof -i ":$port" -sTCP:LISTEN -t 2>/dev/null || true
    elif command -v ss &> /dev/null; then
        ss -tulpn 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d',' -f2 | cut -d'=' -f2 || true
    elif command -v netstat &> /dev/null; then
        netstat -tulpn 2>/dev/null | grep ":$port " | awk '{print $7}' | cut -d'/' -f1 || true
    fi
}

check_port_conflicts() {
    local mode="$1"
    local conflicts=()

    # Extract ports for this mode
    local ports="${STACK_PORTS[$mode]}"

    # Check each port used by this mode
    while IFS=',' read -ra PORT_PAIRS; do
        for pair in "${PORT_PAIRS[@]}"; do
            local port=$(echo "$pair" | cut -d':' -f1 | xargs)
            local pid=$(get_port_usage "$port")

            if [[ -n "$pid" ]]; then
                conflicts+=("Port $port is in use by PID $pid")
            fi
        done
    done <<< "$ports"

    if [ ${#conflicts[@]} -gt 0 ]; then
        log_warning "Port conflicts detected:"
        for conflict in "${conflicts[@]}"; do
            log_warning "  - $conflict"
        done
        return 1
    fi

    return 0
}

# ============================================================
# Stack Detection Functions
# ============================================================

get_running_stacks() {
    local running=()

    for mode in "${!STACK_COMPOSE_FILES[@]}"; do
        if is_stack_running "$mode"; then
            running+=("$mode")
        fi
    done

    echo "${running[@]}"
}

is_stack_running() {
    local mode="$1"
    local compose_file="${STACK_COMPOSE_FILES[$mode]}"

    # Get containers from this stack
    local containers=$(docker-compose -f "$compose_file" ps -q 2>/dev/null || true)

    if [[ -n "$containers" ]]; then
        return 0
    fi

    return 1
}

get_stack_status() {
    local mode="$1"
    local compose_file="${STACK_COMPOSE_FILES[$mode]}"

    if [[ ! -f "$compose_file" ]]; then
        echo "not-found"
        return
    fi

    # Get container statuses
    local running=$(docker-compose -f "$compose_file" ps --filter "status=running" -q 2>/dev/null | wc -l)
    local total=$(docker-compose -f "$compose_file" ps -q 2>/dev/null | wc -l)

    if [[ $total -eq 0 ]]; then
        echo "stopped"
    elif [[ $running -eq $total ]]; then
        echo "running"
    elif [[ $running -gt 0 ]]; then
        echo "partial"
    else
        echo "stopped"
    fi
}

# ============================================================
# Stack Management Functions
# ============================================================

start_stack() {
    local mode="$1"
    local with_tools="${2:-false}"

    log_step "Starting $mode stack..."

    # Validate mode
    if ! validate_mode "$mode"; then
        return 1
    fi

    local compose_file="${STACK_COMPOSE_FILES[$mode]}"

    # Check if already running
    if is_stack_running "$mode"; then
        log_warning "$mode stack is already running"
        return 0
    fi

    # Check for port conflicts
    if ! check_port_conflicts "$mode"; then
        log_error "Cannot start $mode stack due to port conflicts"
        log_info "Stop conflicting stacks or services first"
        return 1
    fi

    # Check for conflicting stacks
    local running_stacks=$(get_running_stacks)
    if [[ -n "$running_stacks" ]]; then
        log_warning "Other stacks are running: $running_stacks"
        read -p "Do you want to stop them first? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for stack in $running_stacks; do
                stop_stack "$stack" false
            done
        else
            log_error "Aborted"
            return 1
        fi
    fi

    # Start the stack
    log_step "Pulling latest images..."
    if [[ "$with_tools" == "true" ]]; then
        docker-compose -f "$compose_file" --profile tools pull 2>&1 | tee -a "$LOG_FILE"
    else
        docker-compose -f "$compose_file" pull 2>&1 | tee -a "$LOG_FILE"
    fi

    log_step "Starting containers..."
    if [[ "$with_tools" == "true" ]]; then
        docker-compose -f "$compose_file" --profile tools up -d 2>&1 | tee -a "$LOG_FILE"
    else
        docker-compose -f "$compose_file" up -d 2>&1 | tee -a "$LOG_FILE"
    fi

    # Wait for health checks
    log_step "Waiting for services to be healthy..."
    sleep 5

    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local status=$(get_stack_status "$mode")
        if [[ "$status" == "running" ]]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    # Display status
    show_stack_info "$mode"

    log_success "$mode stack started successfully"
    return 0
}

stop_stack() {
    local mode="$1"
    local force="${2:-false}"

    log_step "Stopping $mode stack..."

    # Validate mode
    if ! validate_mode "$mode"; then
        return 1
    fi

    local compose_file="${STACK_COMPOSE_FILES[$mode]}"

    # Check if running
    if ! is_stack_running "$mode"; then
        log_warning "$mode stack is not running"
        return 0
    fi

    # Stop the stack
    if [[ "$force" == "true" ]]; then
        log_step "Force stopping containers..."
        docker-compose -f "$compose_file" kill 2>&1 | tee -a "$LOG_FILE"
    fi

    log_step "Stopping containers..."
    docker-compose -f "$compose_file" down 2>&1 | tee -a "$LOG_FILE"

    log_success "$mode stack stopped successfully"
    return 0
}

restart_stack() {
    local mode="$1"
    local with_tools="${2:-false}"

    log_step "Restarting $mode stack..."

    stop_stack "$mode" false
    sleep 2
    start_stack "$mode" "$with_tools"
}

clean_stack() {
    local mode="$1"

    log_step "Cleaning $mode stack..."

    # Validate mode
    if ! validate_mode "$mode"; then
        return 1
    fi

    local compose_file="${STACK_COMPOSE_FILES[$mode]}"

    # Confirm
    log_warning "This will remove all containers and volumes for $mode stack"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted"
        return 0
    fi

    # Stop and remove
    log_step "Stopping and removing containers and volumes..."
    docker-compose -f "$compose_file" down -v 2>&1 | tee -a "$LOG_FILE"

    log_success "$mode stack cleaned successfully"
    return 0
}

show_logs() {
    local mode="$1"
    local follow="${2:-false}"

    # Validate mode
    if ! validate_mode "$mode"; then
        return 1
    fi

    local compose_file="${STACK_COMPOSE_FILES[$mode]}"

    if [[ "$follow" == "true" ]]; then
        log_info "Following logs for $mode stack (Ctrl+C to exit)..."
        docker-compose -f "$compose_file" logs -f --tail=100
    else
        docker-compose -f "$compose_file" logs --tail=100
    fi
}

# ============================================================
# Status Display Functions
# ============================================================

show_stack_info() {
    local mode="$1"

    echo
    echo -e "${BOLD}=== $mode Stack Information ===${NC}"
    echo
    echo -e "${BOLD}Description:${NC} ${STACK_DESCRIPTIONS[$mode]}"
    echo -e "${BOLD}Compose File:${NC} ${STACK_COMPOSE_FILES[$mode]}"
    echo -e "${BOLD}Status:${NC} $(get_stack_status_colored "$mode")"
    echo
    echo -e "${BOLD}Ports:${NC}"
    echo "  ${STACK_PORTS[$mode]}"
    echo
    echo -e "${BOLD}URLs:${NC}"
    echo "  ${STACK_URLS[$mode]}"
    echo

    # Show container status
    local compose_file="${STACK_COMPOSE_FILES[$mode]}"
    if is_stack_running "$mode"; then
        echo -e "${BOLD}Containers:${NC}"
        docker-compose -f "$compose_file" ps --format table
    fi
    echo
}

get_stack_status_colored() {
    local mode="$1"
    local status=$(get_stack_status "$mode")

    case "$status" in
        "running")
            echo -e "${GREEN}Running${NC}"
            ;;
        "partial")
            echo -e "${YELLOW}Partially Running${NC}"
            ;;
        "stopped")
            echo -e "${RED}Stopped${NC}"
            ;;
        "not-found")
            echo -e "${RED}Not Found${NC}"
            ;;
        *)
            echo -e "${YELLOW}Unknown${NC}"
            ;;
    esac
}

show_all_status() {
    echo
    echo -e "${BOLD}=== Stack Manager Status Dashboard ===${NC}"
    echo

    # Show resource usage
    show_resource_usage

    echo
    echo -e "${BOLD}Available Stacks:${NC}"
    echo

    printf "%-15s %-20s %-50s\n" "MODE" "STATUS" "DESCRIPTION"
    printf "%-15s %-20s %-50s\n" "$(printf '%.0s-' {1..15})" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..50})"

    for mode in dev citus patroni monitoring production; do
        local status=$(get_stack_status_colored "$mode")
        local desc="${STACK_DESCRIPTIONS[$mode]}"

        # Truncate description if too long
        if [[ ${#desc} -gt 47 ]]; then
            desc="${desc:0:44}..."
        fi

        printf "%-15s %-20s %-50s\n" "$mode" "$(echo -e "$status")" "$desc"
    done

    echo

    # Show running stacks
    local running_stacks=$(get_running_stacks)
    if [[ -n "$running_stacks" ]]; then
        echo -e "${BOLD}Currently Running:${NC} $running_stacks"
    else
        echo -e "${BOLD}Currently Running:${NC} None"
    fi

    echo
}

show_resource_usage() {
    echo -e "${BOLD}System Resources:${NC}"

    # Docker info
    local containers_running=$(docker ps -q | wc -l)
    local containers_total=$(docker ps -aq | wc -l)
    local images=$(docker images -q | wc -l)
    local volumes=$(docker volume ls -q | wc -l)

    echo "  Containers: $containers_running running / $containers_total total"
    echo "  Images: $images"
    echo "  Volumes: $volumes"

    # System resources (if available)
    if command -v free &> /dev/null; then
        local mem_used=$(free -h | awk 'NR==2 {print $3}')
        local mem_total=$(free -h | awk 'NR==2 {print $2}')
        echo "  Memory: $mem_used / $mem_total"
    fi

    if command -v df &> /dev/null; then
        local disk_used=$(df -h / | awk 'NR==2 {print $3}')
        local disk_total=$(df -h / | awk 'NR==2 {print $2}')
        echo "  Disk: $disk_used / $disk_total"
    fi
}

# ============================================================
# Interactive Mode
# ============================================================

show_menu() {
    clear
    echo
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     Distributed PostgreSQL - Stack Manager v1.0.0        ║${NC}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo

    show_all_status

    echo -e "${BOLD}Actions:${NC}"
    echo
    echo "  1) Start dev stack"
    echo "  2) Start citus stack"
    echo "  3) Start patroni stack"
    echo "  4) Start monitoring stack"
    echo "  5) Start production stack"
    echo
    echo "  6) Stop a stack"
    echo "  7) Restart a stack"
    echo "  8) View logs"
    echo "  9) Clean a stack"
    echo
    echo " 10) Refresh status"
    echo "  0) Exit"
    echo
}

interactive_mode() {
    while true; do
        show_menu

        read -p "Select an option: " choice

        case "$choice" in
            1)
                echo
                read -p "Start with PgAdmin? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    start_stack "dev" true
                else
                    start_stack "dev" false
                fi
                read -p "Press Enter to continue..." -r
                ;;
            2)
                echo
                read -p "Start with PgAdmin? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    start_stack "citus" true
                else
                    start_stack "citus" false
                fi
                read -p "Press Enter to continue..." -r
                ;;
            3)
                start_stack "patroni" false
                read -p "Press Enter to continue..." -r
                ;;
            4)
                start_stack "monitoring" false
                read -p "Press Enter to continue..." -r
                ;;
            5)
                start_stack "production" false
                read -p "Press Enter to continue..." -r
                ;;
            6)
                echo
                read -p "Enter mode to stop (dev/citus/patroni/monitoring/production): " mode
                stop_stack "$mode" false
                read -p "Press Enter to continue..." -r
                ;;
            7)
                echo
                read -p "Enter mode to restart (dev/citus/patroni/monitoring/production): " mode
                restart_stack "$mode" false
                read -p "Press Enter to continue..." -r
                ;;
            8)
                echo
                read -p "Enter mode to view logs (dev/citus/patroni/monitoring/production): " mode
                echo
                read -p "Follow logs? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    show_logs "$mode" true
                else
                    show_logs "$mode" false
                    read -p "Press Enter to continue..." -r
                fi
                ;;
            9)
                echo
                read -p "Enter mode to clean (dev/citus/patroni/monitoring/production): " mode
                clean_stack "$mode"
                read -p "Press Enter to continue..." -r
                ;;
            10)
                # Just refresh by showing menu again
                ;;
            0)
                log_info "Exiting..."
                exit 0
                ;;
            *)
                log_error "Invalid option"
                read -p "Press Enter to continue..." -r
                ;;
        esac
    done
}

# ============================================================
# Main Function
# ============================================================

show_usage() {
    cat << EOF
${BOLD}Stack Manager - Distributed PostgreSQL Cluster${NC}

${BOLD}USAGE:${NC}
    $0 <command> [arguments]

${BOLD}COMMANDS:${NC}
    start <mode>       Start a stack
    stop <mode>        Stop a stack
    restart <mode>     Restart a stack
    status             Show status of all stacks
    logs <mode>        Show logs for a stack
    clean <mode>       Stop and remove volumes
    interactive        Interactive menu mode

${BOLD}MODES:${NC}
    dev               ${STACK_DESCRIPTIONS[dev]}
    citus             ${STACK_DESCRIPTIONS[citus]}
    patroni           ${STACK_DESCRIPTIONS[patroni]}
    monitoring        ${STACK_DESCRIPTIONS[monitoring]}
    production        ${STACK_DESCRIPTIONS[production]}

${BOLD}EXAMPLES:${NC}
    $0 start dev                    # Start development stack
    $0 stop citus                   # Stop citus stack
    $0 restart patroni              # Restart patroni stack
    $0 status                       # Show all stacks status
    $0 logs monitoring              # Show monitoring logs
    $0 clean dev                    # Clean dev stack (removes volumes)
    $0 interactive                  # Start interactive mode

${BOLD}NOTES:${NC}
    - The script will detect and warn about port conflicts
    - Logs are written to: $LOG_FILE
    - Use interactive mode for menu-driven interface

EOF
}

main() {
    # Setup
    setup_logging

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Check Docker
    if ! check_docker_running; then
        exit 1
    fi

    # Handle commands
    case "${1:-}" in
        start)
            if [[ $# -lt 2 ]]; then
                log_error "Missing mode argument"
                show_usage
                exit 1
            fi

            local with_tools=false
            if [[ "${3:-}" == "--tools" ]] || [[ "${3:-}" == "-t" ]]; then
                with_tools=true
            fi

            start_stack "$2" "$with_tools"
            ;;

        stop)
            if [[ $# -lt 2 ]]; then
                log_error "Missing mode argument"
                show_usage
                exit 1
            fi

            local force=false
            if [[ "${3:-}" == "--force" ]] || [[ "${3:-}" == "-f" ]]; then
                force=true
            fi

            stop_stack "$2" "$force"
            ;;

        restart)
            if [[ $# -lt 2 ]]; then
                log_error "Missing mode argument"
                show_usage
                exit 1
            fi

            local with_tools=false
            if [[ "${3:-}" == "--tools" ]] || [[ "${3:-}" == "-t" ]]; then
                with_tools=true
            fi

            restart_stack "$2" "$with_tools"
            ;;

        status)
            show_all_status
            ;;

        logs)
            if [[ $# -lt 2 ]]; then
                log_error "Missing mode argument"
                show_usage
                exit 1
            fi

            local follow=false
            if [[ "${3:-}" == "--follow" ]] || [[ "${3:-}" == "-f" ]]; then
                follow=true
            fi

            show_logs "$2" "$follow"
            ;;

        clean)
            if [[ $# -lt 2 ]]; then
                log_error "Missing mode argument"
                show_usage
                exit 1
            fi

            clean_stack "$2"
            ;;

        interactive|menu)
            interactive_mode
            ;;

        help|--help|-h)
            show_usage
            ;;

        *)
            log_error "Unknown command: ${1:-}"
            echo
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
