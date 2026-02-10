#!/bin/bash
#
# PostgreSQL TLS Certificate Generation Script
# ==============================================
# Generates self-signed CA and server/client certificates for PostgreSQL cluster
#
# Usage: ./generate-certificates.sh [--ca-only | --renew]
#

set -euo pipefail

# Configuration
CERT_DIR="/home/matt/projects/Distributed-Postgress-Cluster/config/security/certs"
COUNTRY="US"
STATE="California"
CITY="San Francisco"
ORG="Distributed PostgreSQL Cluster"
OU="Database Security"
CA_VALIDITY_DAYS=1825  # 5 years
CERT_VALIDITY_DAYS=365  # 1 year
KEY_SIZE=4096

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create certificate directory
mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

# Check if CA already exists
if [[ -f "ca.key" ]] && [[ "$*" != *"--renew"* ]]; then
    log_warn "CA certificate already exists. Use --renew to regenerate."
    CA_EXISTS=true
else
    CA_EXISTS=false
fi

# ============================================================================
# 1. Generate Certificate Authority (CA)
# ============================================================================

if [[ "$CA_EXISTS" == false ]] || [[ "$*" == *"--renew"* ]]; then
    log_info "Generating Certificate Authority (CA)..."

    # Generate CA private key (4096-bit RSA, AES-256 encrypted)
    openssl genrsa -aes256 -out ca.key $KEY_SIZE

    # Generate CA certificate (self-signed, 5-year validity)
    openssl req -new -x509 -days $CA_VALIDITY_DAYS -key ca.key -out ca.crt \
        -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=PostgreSQL CA"

    # Create empty CRL (Certificate Revocation List)
    touch crl.pem

    log_info "CA certificate generated: ca.crt (valid for 5 years)"

    if [[ "$*" == *"--ca-only"* ]]; then
        log_info "CA-only mode. Exiting."
        exit 0
    fi
fi

# ============================================================================
# 2. Generate Server Certificates (Coordinator + Workers)
# ============================================================================

log_info "Generating server certificates..."

# Coordinator certificate
log_info "Generating coordinator certificate..."
openssl genrsa -out coordinator.key $KEY_SIZE
openssl req -new -key coordinator.key -out coordinator.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=pg-coordinator"

# Add SAN (Subject Alternative Names) for multiple hostnames
cat > coordinator-san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = pg-coordinator
DNS.2 = postgres-coordinator
DNS.3 = coordinator
DNS.4 = localhost
IP.1 = 10.0.10.2
IP.2 = 127.0.0.1
EOF

openssl x509 -req -in coordinator.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out coordinator.crt -days $CERT_VALIDITY_DAYS \
    -extensions v3_req -extfile coordinator-san.cnf

log_info "Coordinator certificate: coordinator.crt"

# Worker certificates
for worker_id in 1 2 3; do
    log_info "Generating worker-${worker_id} certificate..."

    openssl genrsa -out worker-${worker_id}.key $KEY_SIZE
    openssl req -new -key worker-${worker_id}.key -out worker-${worker_id}.csr \
        -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=pg-worker-${worker_id}"

    # SAN configuration
    cat > worker-${worker_id}-san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req

[req_distinguished_name]

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = pg-worker-${worker_id}
DNS.2 = postgres-worker-${worker_id}
DNS.3 = worker-${worker_id}
IP.1 = 10.0.10.$((2 + worker_id))
EOF

    openssl x509 -req -in worker-${worker_id}.csr -CA ca.crt -CAkey ca.key \
        -CAcreateserial -out worker-${worker_id}.crt -days $CERT_VALIDITY_DAYS \
        -extensions v3_req -extfile worker-${worker_id}-san.cnf

    log_info "Worker-${worker_id} certificate: worker-${worker_id}.crt"
done

# ============================================================================
# 3. Generate Client Certificates
# ============================================================================

log_info "Generating client certificates..."

# Replication user certificate
log_info "Generating replication user certificate..."
openssl genrsa -out replicator.key $KEY_SIZE
openssl req -new -key replicator.key -out replicator.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=replicator"
openssl x509 -req -in replicator.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out replicator.crt -days $CERT_VALIDITY_DAYS

# Application client certificate (generic)
log_info "Generating application client certificate..."
openssl genrsa -out app_client.key $KEY_SIZE
openssl req -new -key app_client.key -out app_client.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=app_writer"
openssl x509 -req -in app_client.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out app_client.crt -days $CERT_VALIDITY_DAYS

# Admin client certificate
log_info "Generating admin client certificate..."
openssl genrsa -out admin_client.key $KEY_SIZE
openssl req -new -key admin_client.key -out admin_client.csr \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=cluster_admin"
openssl x509 -req -in admin_client.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out admin_client.crt -days $CERT_VALIDITY_DAYS

# ============================================================================
# 4. Generate DH Parameters (Perfect Forward Secrecy)
# ============================================================================

log_info "Generating Diffie-Hellman parameters (this may take several minutes)..."
openssl dhparam -out dhparams.pem 4096

# ============================================================================
# 5. Set Proper Permissions
# ============================================================================

log_info "Setting certificate permissions..."

# Private keys: read-only by owner (600)
chmod 600 *.key

# Certificates: readable by all (644)
chmod 644 *.crt ca.crt dhparams.pem

# CA key: extra protection (400)
chmod 400 ca.key

# ============================================================================
# 6. Verify Certificates
# ============================================================================

log_info "Verifying certificates..."

# Verify coordinator certificate
if openssl verify -CAfile ca.crt coordinator.crt > /dev/null 2>&1; then
    log_info "Coordinator certificate verified successfully"
else
    log_error "Coordinator certificate verification failed"
fi

# Verify worker certificates
for worker_id in 1 2 3; do
    if openssl verify -CAfile ca.crt worker-${worker_id}.crt > /dev/null 2>&1; then
        log_info "Worker-${worker_id} certificate verified successfully"
    else
        log_error "Worker-${worker_id} certificate verification failed"
    fi
done

# Verify client certificates
for cert in replicator.crt app_client.crt admin_client.crt; do
    if openssl verify -CAfile ca.crt $cert > /dev/null 2>&1; then
        log_info "$cert verified successfully"
    else
        log_error "$cert verification failed"
    fi
done

# ============================================================================
# 7. Display Certificate Information
# ============================================================================

log_info "Certificate generation complete!"
echo ""
echo "Certificate Summary:"
echo "===================="
echo "CA Certificate: ca.crt (valid until $(openssl x509 -enddate -noout -in ca.crt | cut -d= -f2))"
echo ""
echo "Server Certificates:"
echo "  - coordinator.crt (CN=pg-coordinator)"
echo "  - worker-1.crt (CN=pg-worker-1)"
echo "  - worker-2.crt (CN=pg-worker-2)"
echo "  - worker-3.crt (CN=pg-worker-3)"
echo ""
echo "Client Certificates:"
echo "  - replicator.crt (CN=replicator)"
echo "  - app_client.crt (CN=app_writer)"
echo "  - admin_client.crt (CN=cluster_admin)"
echo ""
echo "DH Parameters: dhparams.pem (4096-bit)"
echo ""

# ============================================================================
# 8. Create Docker Secrets (if Docker Swarm is initialized)
# ============================================================================

if docker info 2>/dev/null | grep -q "Swarm: active"; then
    log_info "Docker Swarm detected. Creating Docker secrets..."

    # Remove existing secrets (ignore errors)
    docker secret rm postgres_ca_cert 2>/dev/null || true
    docker secret rm postgres_coordinator_cert 2>/dev/null || true
    docker secret rm postgres_coordinator_key 2>/dev/null || true

    # Create new secrets
    docker secret create postgres_ca_cert ca.crt
    docker secret create postgres_coordinator_cert coordinator.crt
    docker secret create postgres_coordinator_key coordinator.key

    log_info "Docker secrets created successfully"
else
    log_warn "Docker Swarm not initialized. Skipping secret creation."
    log_warn "Initialize swarm with: docker swarm init"
fi

# ============================================================================
# 9. Generate Connection Strings
# ============================================================================

cat > connection-examples.txt <<EOF
PostgreSQL Connection Examples (with TLS)
==========================================

1. psql (command-line):
psql "host=pg-coordinator port=5432 dbname=distributed_postgres_cluster user=app_writer \\
      sslmode=verify-full sslcert=$CERT_DIR/app_client.crt \\
      sslkey=$CERT_DIR/app_client.key sslrootcert=$CERT_DIR/ca.crt"

2. Python (psycopg2):
import psycopg2
conn = psycopg2.connect(
    host="pg-coordinator",
    port=5432,
    database="distributed_postgres_cluster",
    user="app_writer",
    sslmode="verify-full",
    sslcert="$CERT_DIR/app_client.crt",
    sslkey="$CERT_DIR/app_client.key",
    sslrootcert="$CERT_DIR/ca.crt"
)

3. JDBC (Java):
jdbc:postgresql://pg-coordinator:5432/distributed_postgres_cluster?\\
    user=app_writer&\\
    ssl=true&\\
    sslmode=verify-full&\\
    sslcert=$CERT_DIR/app_client.crt&\\
    sslkey=$CERT_DIR/app_client.key&\\
    sslrootcert=$CERT_DIR/ca.crt

4. Connection String (libpq):
postgresql://app_writer@pg-coordinator:5432/distributed_postgres_cluster?\\
    sslmode=verify-full&\\
    sslcert=$CERT_DIR/app_client.crt&\\
    sslkey=$CERT_DIR/app_client.key&\\
    sslrootcert=$CERT_DIR/ca.crt

EOF

log_info "Connection examples saved to: connection-examples.txt"

# ============================================================================
# 10. Certificate Expiry Check Script
# ============================================================================

cat > check-cert-expiry.sh <<'EOF'
#!/bin/bash
# Check certificate expiry dates

CERT_DIR="$(dirname "$0")"
WARN_DAYS=30

echo "Certificate Expiry Report"
echo "========================="
echo ""

for cert in "$CERT_DIR"/*.crt; do
    if [[ -f "$cert" ]]; then
        cert_name=$(basename "$cert")
        expiry_date=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
        expiry_epoch=$(date -d "$expiry_date" +%s)
        current_epoch=$(date +%s)
        days_remaining=$(( ($expiry_epoch - $current_epoch) / 86400 ))

        if [[ $days_remaining -lt 0 ]]; then
            echo "❌ $cert_name: EXPIRED on $expiry_date"
        elif [[ $days_remaining -lt $WARN_DAYS ]]; then
            echo "⚠️  $cert_name: Expires in $days_remaining days ($expiry_date)"
        else
            echo "✅ $cert_name: Valid for $days_remaining days ($expiry_date)"
        fi
    fi
done
EOF

chmod +x check-cert-expiry.sh
log_info "Certificate expiry checker: check-cert-expiry.sh"

echo ""
log_info "Next steps:"
echo "  1. Review certificates: ls -lh $CERT_DIR"
echo "  2. Test certificate: openssl s_client -connect pg-coordinator:5432 -starttls postgres"
echo "  3. Deploy to Docker Swarm: docker stack deploy -c stack.yml postgres-cluster"
echo "  4. Check expiry: $CERT_DIR/check-cert-expiry.sh"
echo ""
