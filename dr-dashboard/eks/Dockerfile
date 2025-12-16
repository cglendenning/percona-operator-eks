# Dockerfile for DR Dashboard (EKS)
#
# Build from repository root:
#   docker build -f dr-dashboard/eks/Dockerfile -t dr-dashboard-eks .

# Build stage
FROM golang:1.21-alpine AS builder

WORKDIR /build

RUN apk add --no-cache git

COPY dr-dashboard/eks/go.mod ./
RUN go mod download 2>/dev/null || true

COPY dr-dashboard/eks/main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o dr-dashboard main.go

# Runtime stage
FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app
RUN mkdir -p /app/static /app/data/recovery_processes /app/data/scenarios

COPY --from=builder /build/dr-dashboard /app/dr-dashboard
COPY dr-dashboard/eks/static/ /app/static/
COPY dr-dashboard/recovery_processes/eks/ /app/data/recovery_processes/
COPY testing/eks/disaster_scenarios/disaster_scenarios.json /app/data/scenarios/disaster_scenarios.json

ENV DATA_DIR=/app/data
ENV STATIC_DIR=/app/static
ENV PORT=8080

RUN chown -R appuser:appgroup /app
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1

ENTRYPOINT ["/app/dr-dashboard"]
