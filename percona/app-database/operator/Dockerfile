ARG BUILDPLATFORM
ARG TARGETPLATFORM
FROM --platform=$BUILDPLATFORM python:3.11-slim AS builder

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy operator code
COPY operator.py .
COPY handlers/ ./handlers/

FROM --platform=$TARGETPLATFORM python:3.11-slim
WORKDIR /app
COPY --from=builder /usr/local /usr/local
COPY --from=builder /app /app

# Run as non-root user
RUN adduser --disabled-password --gecos "" dbconcierge && \
    chown -R dbconcierge:dbconcierge /app
USER dbconcierge

CMD ["kopf", "run", "--liveness=http://0.0.0.0:8080/healthz", "operator.py"]

