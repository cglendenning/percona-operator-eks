# syntax=docker/dockerfile:1
# Build: tsc + esbuild bundle, mirroring pxc-async-replica.
FROM node:20-bookworm-slim AS builder
WORKDIR /build

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build \
  && npx esbuild dist/index.js \
    --bundle --platform=node --target=node20 --format=cjs \
    --outfile=/build/bundle.cjs

FROM node:20-bookworm-slim AS runtime
WORKDIR /
ENV NODE_ENV=production

COPY --from=builder /build/bundle.cjs /app/bundle.cjs

USER node
CMD ["node", "/app/bundle.cjs"]
