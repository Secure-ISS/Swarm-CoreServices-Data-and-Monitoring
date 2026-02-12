#!/bin/bash
# Cluster Performance Benchmark Script
# Quick performance snapshot and comparison against baselines
# Usage: ./benchmark-cluster.sh [action: run|compare|report]

set -euo pipefail

# Configuration
CONTAINER_NAME="ruvector-db"
BENCHMARK_DIR="/tmp/benchmarks"
BASELINE_FILE="${BENCHMARK_DIR}/baseline.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_metric() { echo -e "${CYAN}[METRIC]${NC} $*"; }

# Check if container is running
check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container ${CONTAINER_NAME} is not running"
        exit 1
    fi
}

# Initialize benchmark directory
init_benchmark_dir() {
    mkdir -p "$BENCHMARK_DIR"
}

# Run comprehensive benchmark
run_benchmark() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local result_file="${BENCHMARK_DIR}/benchmark_${timestamp}.json"

    log_info "Running comprehensive benchmark..."
    log_info "Results will be saved to: $result_file"

    # Start JSON output
    echo "{" > "$result_file"
    echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$result_file"
    echo "  \"metrics\": {" >> "$result_file"

    # 1. Connection Test
    log_info "[1/8] Testing database connections..."
    local conn_start=$(date +%s%N)
    for i in {1..100}; do
        docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -c "SELECT 1;" > /dev/null 2>&1
    done
    local conn_end=$(date +%s%N)
    local conn_time=$(( (conn_end - conn_start) / 1000000 )) # Convert to ms
    local conn_avg=$((conn_time / 100))
    log_metric "Connection time (avg): ${conn_avg}ms"
    echo "    \"connection_avg_ms\": $conn_avg," >> "$result_file"

    # 2. Simple Query Performance
    log_info "[2/8] Testing simple query performance..."
    local simple_result=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A <<'EOF'
\timing on
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
BEGIN
    start_time := clock_timestamp();
    PERFORM COUNT(*) FROM pg_stat_user_tables;
    end_time := clock_timestamp();
    RAISE NOTICE '%', EXTRACT(MILLISECONDS FROM (end_time - start_time));
END $$;
EOF
    )
    local simple_time=$(echo "$simple_result" | grep -oP '\d+\.\d+' | head -1)
    log_metric "Simple query time: ${simple_time}ms"
    echo "    \"simple_query_ms\": ${simple_time:-0}," >> "$result_file"

    # 3. Index Scan Performance
    log_info "[3/8] Testing index scan performance..."
    local index_result=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A <<'EOF'
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    result_count int;
BEGIN
    start_time := clock_timestamp();
    SELECT COUNT(*) INTO result_count FROM claude_flow.memory_entries WHERE id < 1000;
    end_time := clock_timestamp();
    RAISE NOTICE '%', EXTRACT(MILLISECONDS FROM (end_time - start_time));
END $$;
EOF
    )
    local index_time=$(echo "$index_result" | grep -oP '\d+\.\d+' | head -1)
    log_metric "Index scan time: ${index_time}ms"
    echo "    \"index_scan_ms\": ${index_time:-0}," >> "$result_file"

    # 4. Vector Search Performance
    log_info "[4/8] Testing vector search performance..."
    local vector_result=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A <<'EOF'
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    test_vector ruvector(1536);
    result_id int;
BEGIN
    -- Generate random vector
    test_vector := ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
    FROM generate_series(1, 1536);

    -- Create temp table with vectors
    CREATE TEMP TABLE IF NOT EXISTS temp_vectors (
        id SERIAL PRIMARY KEY,
        embedding ruvector(1536)
    );

    -- Insert test vectors if empty
    INSERT INTO temp_vectors (embedding)
    SELECT ('['||string_agg(random()::text, ',')||']')::ruvector(1536)
    FROM generate_series(1, 100) s
    CROSS JOIN generate_series(1, 1536)
    GROUP BY s
    ON CONFLICT DO NOTHING;

    -- Create index
    CREATE INDEX IF NOT EXISTS idx_temp_vectors_hnsw ON temp_vectors
    USING hnsw (embedding ruvector_cosine_ops) WITH (m = 16, ef_construction = 100);

    -- Test search
    start_time := clock_timestamp();
    SELECT id INTO result_id FROM temp_vectors
    ORDER BY embedding <=> test_vector
    LIMIT 1;
    end_time := clock_timestamp();

    RAISE NOTICE '%', EXTRACT(MILLISECONDS FROM (end_time - start_time));
END $$;
EOF
    )
    local vector_time=$(echo "$vector_result" | grep -oP '\d+\.\d+' | head -1)
    log_metric "Vector search time: ${vector_time}ms"
    echo "    \"vector_search_ms\": ${vector_time:-0}," >> "$result_file"

    # 5. Write Performance
    log_info "[5/8] Testing write performance..."
    local write_result=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A <<'EOF'
DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS temp_writes (id SERIAL, data TEXT);

    start_time := clock_timestamp();
    INSERT INTO temp_writes (data)
    SELECT 'test_data_' || i
    FROM generate_series(1, 1000) i;
    end_time := clock_timestamp();

    RAISE NOTICE '%', EXTRACT(MILLISECONDS FROM (end_time - start_time));

    DROP TABLE temp_writes;
END $$;
EOF
    )
    local write_time=$(echo "$write_result" | grep -oP '\d+\.\d+' | head -1)
    log_metric "Write performance (1000 rows): ${write_time}ms"
    echo "    \"write_1000_rows_ms\": ${write_time:-0}," >> "$result_file"

    # 6. Cache Hit Ratio
    log_info "[6/8] Calculating cache hit ratio..."
    local cache_ratio=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT ROUND(100.0 * sum(heap_blks_hit) / NULLIF(sum(heap_blks_hit + heap_blks_read), 0), 2)
        FROM pg_statio_user_tables;
    ")
    log_metric "Cache hit ratio: ${cache_ratio}%"
    echo "    \"cache_hit_ratio_percent\": ${cache_ratio:-0}," >> "$result_file"

    # 7. Connection Pool Usage
    log_info "[7/8] Checking connection pool usage..."
    local active_conns=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT count(*) FROM pg_stat_activity WHERE datname = 'distributed_postgres_cluster';
    ")
    local max_conns=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SHOW max_connections;
    ")
    local conn_usage=$((active_conns * 100 / max_conns))
    log_metric "Active connections: ${active_conns}/${max_conns} (${conn_usage}%)"
    echo "    \"active_connections\": $active_conns," >> "$result_file"
    echo "    \"max_connections\": $max_conns," >> "$result_file"
    echo "    \"connection_usage_percent\": $conn_usage," >> "$result_file"

    # 8. Database Size
    log_info "[8/8] Calculating database sizes..."
    local db_size=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT pg_database_size(current_database());
    ")
    local table_size=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT SUM(pg_total_relation_size(schemaname||'.'||tablename))
        FROM pg_tables
        WHERE schemaname IN ('public', 'claude_flow');
    ")
    local index_size=$(docker exec "$CONTAINER_NAME" psql -U dpg_cluster -d distributed_postgres_cluster -t -A -c "
        SELECT SUM(pg_relation_size(indexrelid))
        FROM pg_stat_user_indexes
        WHERE schemaname IN ('public', 'claude_flow');
    ")
    log_metric "Database size: $(numfmt --to=iec $db_size)"
    log_metric "Table size: $(numfmt --to=iec $table_size)"
    log_metric "Index size: $(numfmt --to=iec $index_size)"

    # Close JSON
    echo "    \"database_size_bytes\": $db_size," >> "$result_file"
    echo "    \"table_size_bytes\": $table_size," >> "$result_file"
    echo "    \"index_size_bytes\": $index_size" >> "$result_file"
    echo "  }" >> "$result_file"
    echo "}" >> "$result_file"

    log_success "Benchmark completed!"
    log_info "Results saved to: $result_file"

    # Save as baseline if requested
    if [ "${SAVE_BASELINE:-false}" = "true" ]; then
        cp "$result_file" "$BASELINE_FILE"
        log_success "Saved as new baseline"
    fi

    echo "$result_file"
}

# Compare with baseline
compare_with_baseline() {
    local result_file="$1"

    if [ ! -f "$BASELINE_FILE" ]; then
        log_warning "No baseline found. Run with SAVE_BASELINE=true to create one."
        return
    fi

    log_info "Comparing with baseline..."

    # Extract metrics using grep and basic text processing
    get_metric() {
        local file="$1"
        local key="$2"
        grep "\"$key\"" "$file" | grep -oP '\d+(\.\d+)?' || echo "0"
    }

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║              Performance Comparison vs Baseline                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # Compare each metric
    compare_metric() {
        local name="$1"
        local key="$2"
        local current=$(get_metric "$result_file" "$key")
        local baseline=$(get_metric "$BASELINE_FILE" "$key")

        if [ "$baseline" = "0" ] || [ "$current" = "0" ]; then
            printf "%-30s: %10s  |  %10s  |  N/A\n" "$name" "$current" "$baseline"
            return
        fi

        local diff=$(echo "scale=2; (($current - $baseline) / $baseline) * 100" | bc -l 2>/dev/null || echo "0")
        local symbol=""

        # For latency metrics, lower is better
        if [[ "$key" =~ _ms$ ]]; then
            if (( $(echo "$diff < -5" | bc -l 2>/dev/null || echo 0) )); then
                symbol="${GREEN}↓ $(echo ${diff#-} | cut -c1-5)%${NC}"
            elif (( $(echo "$diff > 5" | bc -l 2>/dev/null || echo 0) )); then
                symbol="${RED}↑ $(echo $diff | cut -c1-5)%${NC}"
            else
                symbol="${YELLOW}→${NC}"
            fi
        # For percentages and counts, higher is usually better
        else
            if (( $(echo "$diff > 5" | bc -l 2>/dev/null || echo 0) )); then
                symbol="${GREEN}↑ $(echo $diff | cut -c1-5)%${NC}"
            elif (( $(echo "$diff < -5" | bc -l 2>/dev/null || echo 0) )); then
                symbol="${RED}↓ $(echo ${diff#-} | cut -c1-5)%${NC}"
            else
                symbol="${YELLOW}→${NC}"
            fi
        fi

        printf "%-30s: %10s  |  %10s  |  " "$name" "$current" "$baseline"
        echo -e "$symbol"
    }

    printf "%-30s   %-10s     %-10s     %s\n" "Metric" "Current" "Baseline" "Change"
    echo "────────────────────────────────────────────────────────────────"

    compare_metric "Connection (avg)" "connection_avg_ms"
    compare_metric "Simple Query" "simple_query_ms"
    compare_metric "Index Scan" "index_scan_ms"
    compare_metric "Vector Search" "vector_search_ms"
    compare_metric "Write (1000 rows)" "write_1000_rows_ms"
    compare_metric "Cache Hit Ratio %" "cache_hit_ratio_percent"
    compare_metric "Connection Usage %" "connection_usage_percent"

    echo ""
}

# Generate HTML report
generate_html_report() {
    local result_file="$1"
    local html_file="${result_file%.json}.html"

    log_info "Generating HTML report..."

    cat > "$html_file" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>PostgreSQL Cluster Benchmark Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
        }
        .metrics {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .metric-card {
            background: white;
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        .metric-title {
            font-size: 14px;
            color: #666;
            margin-bottom: 10px;
        }
        .metric-value {
            font-size: 32px;
            font-weight: bold;
            color: #667eea;
        }
        .metric-unit {
            font-size: 18px;
            color: #999;
        }
        .good { color: #10b981; }
        .warning { color: #f59e0b; }
        .bad { color: #ef4444; }
        table {
            width: 100%;
            background: white;
            border-radius: 10px;
            overflow: hidden;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        th {
            background: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
        }
        td {
            padding: 15px;
            border-bottom: 1px solid #f0f0f0;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>PostgreSQL Cluster Benchmark Report</h1>
        <p>Generated: <span id="timestamp"></span></p>
    </div>

    <div class="metrics" id="metrics"></div>

    <table>
        <thead>
            <tr>
                <th>Metric</th>
                <th>Value</th>
                <th>Status</th>
            </tr>
        </thead>
        <tbody id="details"></tbody>
    </table>

    <script>
        const data = DATA_PLACEHOLDER;

        document.getElementById('timestamp').textContent = new Date(data.timestamp).toLocaleString();

        const metrics = [
            { key: 'connection_avg_ms', title: 'Avg Connection Time', unit: 'ms', threshold: 10 },
            { key: 'simple_query_ms', title: 'Simple Query', unit: 'ms', threshold: 50 },
            { key: 'index_scan_ms', title: 'Index Scan', unit: 'ms', threshold: 100 },
            { key: 'vector_search_ms', title: 'Vector Search', unit: 'ms', threshold: 50 },
            { key: 'write_1000_rows_ms', title: 'Write 1000 Rows', unit: 'ms', threshold: 500 },
            { key: 'cache_hit_ratio_percent', title: 'Cache Hit Ratio', unit: '%', threshold: 90, higherBetter: true }
        ];

        const metricsHtml = metrics.map(m => {
            const value = data.metrics[m.key] || 0;
            let status = '';
            if (m.higherBetter) {
                status = value >= m.threshold ? 'good' : value >= m.threshold * 0.8 ? 'warning' : 'bad';
            } else {
                status = value <= m.threshold ? 'good' : value <= m.threshold * 1.5 ? 'warning' : 'bad';
            }

            return `
                <div class="metric-card">
                    <div class="metric-title">${m.title}</div>
                    <div class="metric-value ${status}">
                        ${value.toFixed(2)}
                        <span class="metric-unit">${m.unit}</span>
                    </div>
                </div>
            `;
        }).join('');

        document.getElementById('metrics').innerHTML = metricsHtml;

        const detailsHtml = Object.entries(data.metrics).map(([key, value]) => {
            return `
                <tr>
                    <td>${key.replace(/_/g, ' ').toUpperCase()}</td>
                    <td>${typeof value === 'number' ? value.toFixed(2) : value}</td>
                    <td>✓</td>
                </tr>
            `;
        }).join('');

        document.getElementById('details').innerHTML = detailsHtml;
    </script>
</body>
</html>
EOF

    # Insert actual data
    local json_data=$(cat "$result_file")
    sed -i "s|DATA_PLACEHOLDER|${json_data}|g" "$html_file"

    log_success "HTML report saved to: $html_file"
}

# Main execution
main() {
    check_container
    init_benchmark_dir

    echo "╔════════════════════════════════════════════════════════╗"
    echo "║       PostgreSQL Cluster Performance Benchmark         ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo

    case "${1:-run}" in
        run)
            local result_file=$(run_benchmark)
            if [ -f "$BASELINE_FILE" ]; then
                compare_with_baseline "$result_file"
            fi
            ;;
        baseline)
            SAVE_BASELINE=true run_benchmark
            ;;
        compare)
            if [ -z "${2:-}" ]; then
                log_error "Usage: $0 compare <result_file>"
                exit 1
            fi
            compare_with_baseline "$2"
            ;;
        report)
            local latest=$(ls -t "${BENCHMARK_DIR}"/benchmark_*.json 2>/dev/null | head -1)
            if [ -z "$latest" ]; then
                log_error "No benchmark results found"
                exit 1
            fi
            generate_html_report "$latest"
            ;;
        *)
            log_error "Unknown action: $1"
            echo "Usage: $0 [action]"
            echo "  run      - Run benchmark and compare with baseline (default)"
            echo "  baseline - Run benchmark and save as new baseline"
            echo "  compare  - Compare result file with baseline"
            echo "  report   - Generate HTML report from latest benchmark"
            exit 1
            ;;
    esac
}

main "$@"
