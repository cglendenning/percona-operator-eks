# Build: tsc then esbundle single CJS entry (same as async-replica.nix postInstall).
# Run:   docker build -t pxc-async-replica-controller:latest .
#        kind load docker-image pxc-async-replica-controller:latest --name …
#        (image name must match Deployment image)

ARG BUILDPLATFORM
ARG TARGETPLATFORM
FROM --platform=$BUILDPLATFORM node:20-bookworm-slim AS builder
WORKDIR /build

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build \
  && npx esbuild dist/index.js \
    --bundle --platform=node --target=node20 --format=cjs \
    --outfile=/build/bundle.cjs

FROM --platform=$TARGETPLATFORM node:20-bookworm-slim AS runtime
WORKDIR /
ENV NODE_ENV=production
# Debian image: system CA bundle path (matches prior Nix image env hint)
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

COPY --from=builder /build/bundle.cjs /app/bundle.cjs

USER node
CMD ["node", "/app/bundle.cjs"]
