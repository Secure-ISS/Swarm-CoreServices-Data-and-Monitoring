#!/bin/bash
# SSL/TLS Certificate Generation Script for PostgreSQL
#
# This script generates self-signed certificates for development and testing.
# For production, use certificates from a trusted Certificate Authority (CA)
# like Let's Encrypt or a commercial CA.

set -e  # Exit on error

# Configuration
CERT_DIR="certs"
VALIDITY_DAYS=3650  # 10 years
COUNTRY="US"
STATE="California"
CITY="San Francisco"
ORG="Distributed PostgreSQL Cluster"
OU="Database Team"
CN="localhost"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=================================================="
echo "PostgreSQL SSL/TLS Certificate Generator"
echo "=================================================="
echo

# Create certificate directory
if [ -d "$CERT_DIR" ]; then
    echo -e "${YELLOW}⚠ Certificate directory already exists${NC}"
    read -p "Overwrite existing certificates? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi
    rm -rf "$CERT_DIR"
fi

mkdir -p "$CERT_DIR"
echo -e "${GREEN}✓ Created certificate directory: $CERT_DIR${NC}"

# Generate CA key and certificate
echo
echo "1. Generating Certificate Authority (CA)..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
openssl req -new -x509 -days $VALIDITY_DAYS -key "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.crt" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=$CN CA" \
    2>/dev/null
echo -e "${GREEN}✓ CA certificate generated${NC}"

# Generate server key and certificate
echo
echo "2. Generating server certificate..."
openssl genrsa -out "$CERT_DIR/server.key" 4096 2>/dev/null
openssl req -new -key "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.csr" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=$CN" \
    2>/dev/null

# Create server certificate extensions file
cat > "$CERT_DIR/server_ext.cnf" <<EOF
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl x509 -req -in "$CERT_DIR/server.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/server.crt" -days $VALIDITY_DAYS \
    -extfile "$CERT_DIR/server_ext.cnf" \
    2>/dev/null

rm "$CERT_DIR/server.csr" "$CERT_DIR/server_ext.cnf"
echo -e "${GREEN}✓ Server certificate generated${NC}"

# Generate client key and certificate
echo
echo "3. Generating client certificate..."
openssl genrsa -out "$CERT_DIR/client.key" 4096 2>/dev/null
openssl req -new -key "$CERT_DIR/client.key" \
    -out "$CERT_DIR/client.csr" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$CITY/O=$ORG/OU=$OU/CN=client" \
    2>/dev/null

# Create client certificate extensions file
cat > "$CERT_DIR/client_ext.cnf" <<EOF
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection
EOF

openssl x509 -req -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/client.crt" -days $VALIDITY_DAYS \
    -extfile "$CERT_DIR/client_ext.cnf" \
    2>/dev/null

rm "$CERT_DIR/client.csr" "$CERT_DIR/client_ext.cnf"
echo -e "${GREEN}✓ Client certificate generated${NC}"

# Set appropriate permissions
echo
echo "4. Setting file permissions..."
chmod 600 "$CERT_DIR"/*.key
chmod 644 "$CERT_DIR"/*.crt
chmod 644 "$CERT_DIR"/*.srl 2>/dev/null || true
echo -e "${GREEN}✓ Permissions set${NC}"

# Verify certificates
echo
echo "5. Verifying certificates..."

# Verify CA certificate
openssl x509 -in "$CERT_DIR/ca.crt" -noout -text > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ CA certificate valid${NC}"
else
    echo -e "${RED}✗ CA certificate invalid${NC}"
    exit 1
fi

# Verify server certificate
openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Server certificate valid${NC}"
else
    echo -e "${RED}✗ Server certificate invalid${NC}"
    exit 1
fi

# Verify client certificate
openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/client.crt" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Client certificate valid${NC}"
else
    echo -e "${RED}✗ Client certificate invalid${NC}"
    exit 1
fi

# Display certificate information
echo
echo "=================================================="
echo "Certificate Summary"
echo "=================================================="
echo
echo "CA Certificate:"
openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject -issuer -dates
echo
echo "Server Certificate:"
openssl x509 -in "$CERT_DIR/server.crt" -noout -subject -issuer -dates
echo
echo "Client Certificate:"
openssl x509 -in "$CERT_DIR/client.crt" -noout -subject -issuer -dates
echo

# Generate configuration snippet
echo
echo "=================================================="
echo "Next Steps"
echo "=================================================="
echo
echo "1. Configure PostgreSQL (postgresql.conf):"
echo "   ssl = on"
echo "   ssl_cert_file = '$(pwd)/$CERT_DIR/server.crt'"
echo "   ssl_key_file = '$(pwd)/$CERT_DIR/server.key'"
echo "   ssl_ca_file = '$(pwd)/$CERT_DIR/ca.crt'"
echo
echo "2. Update .env file:"
echo "   RUVECTOR_SSLMODE=require"
echo "   RUVECTOR_SSLROOTCERT=$(pwd)/$CERT_DIR/ca.crt"
echo "   RUVECTOR_SSLCERT=$(pwd)/$CERT_DIR/client.crt"
echo "   RUVECTOR_SSLKEY=$(pwd)/$CERT_DIR/client.key"
echo
echo "3. Restart PostgreSQL:"
echo "   docker restart ruvector-db"
echo
echo "4. Verify SSL connection:"
echo "   python scripts/db_health_check.py"
echo

echo -e "${GREEN}✓ SSL certificate generation complete!${NC}"
