# Multi-stage Dockerfile for DR Dashboard
# Supports both on-prem and eks variants via build arg
#
# Build from the repository root:
#   docker build -f dr-dashboard/Dockerfile --build-arg ENVIRONMENT=on-prem -t dr-dashboard:on-prem .
#   docker build -f dr-dashboard/Dockerfile --build-arg ENVIRONMENT=eks -t dr-dashboard:eks .

ARG ENVIRONMENT=on-prem

# Build stage
FROM golang:1.21-alpine AS builder

ARG ENVIRONMENT

WORKDIR /build

# Install build dependencies
RUN apk add --no-cache git

# Copy go.mod from the specific environment
COPY dr-dashboard/${ENVIRONMENT}/go.mod ./

# Download dependencies (if any external deps exist)
RUN go mod download 2>/dev/null || true

# Copy source code
COPY dr-dashboard/${ENVIRONMENT}/main.go ./

# Build the binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o dr-dashboard main.go

# Runtime stage
FROM alpine:3.19

ARG ENVIRONMENT

# Install ca-certificates for HTTPS and wget for healthcheck
RUN apk add --no-cache ca-certificates tzdata

# Create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Create directory structure
RUN mkdir -p /app/static /app/data/recovery_processes /app/data/scenarios

# Copy binary from builder
COPY --from=builder /build/dr-dashboard /app/dr-dashboard

# Copy static files for the specific environment
COPY dr-dashboard/${ENVIRONMENT}/static/ /app/static/

# Copy recovery processes for the specific environment
COPY dr-dashboard/recovery_processes/${ENVIRONMENT}/ /app/data/recovery_processes/

# Copy disaster scenarios JSON for the specific environment
COPY testing/${ENVIRONMENT}/disaster_scenarios/disaster_scenarios.json /app/data/scenarios/disaster_scenarios.json

# Set environment variables
ENV ENVIRONMENT=${ENVIRONMENT}
ENV DATA_DIR=/app/data
ENV STATIC_DIR=/app/static
ENV PORT=8080

# Change ownership
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1

ENTRYPOINT ["/app/dr-dashboard"]
