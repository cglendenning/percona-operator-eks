FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy operator code
COPY operator.py .
COPY handlers/ ./handlers/

# Run as non-root user
RUN useradd -m -u 1000 operator && chown -R operator:operator /app
USER operator

CMD ["kopf", "run", "--liveness=http://0.0.0.0:8080/healthz", "operator.py"]

