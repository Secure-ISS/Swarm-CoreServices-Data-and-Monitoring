FROM ruvnet/ruvector-postgres:latest

# Install Patroni and dependencies
RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    python3-psycopg2 \
    python3-etcd \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni via pip
RUN pip3 install --break-system-packages --no-cache-dir \
    patroni[etcd3] \
    psycopg2-binary \
    python-etcd

# Create Patroni directories with correct permissions
RUN mkdir -p /etc/patroni /var/lib/postgresql/data && \
    chown -R postgres:postgres /etc/patroni /var/lib/postgresql && \
    chmod 0700 /var/lib/postgresql/data

# Copy Patroni configuration template
COPY patroni.yml /etc/patroni/patroni.yml
RUN chown postgres:postgres /etc/patroni/patroni.yml

# Switch to postgres user
USER postgres

# Expose PostgreSQL and Patroni REST API ports
EXPOSE 5432 8008

# Health check
HEALTHCHECK --interval=10s --timeout=5s --retries=5 \
    CMD pg_isready -U postgres || exit 1

# Start Patroni (which will manage PostgreSQL)
CMD ["patroni", "/etc/patroni/patroni.yml"]
