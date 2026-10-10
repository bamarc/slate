# Stage 1: Build
FROM node:22-alpine AS builder

WORKDIR /app

# Enable corepack for pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# Configure pnpm store directory
RUN pnpm config set store-dir /pnpm/store

# Copy package config and lockfile
COPY package.json pnpm-lock.yaml* pnpm-workspace.yaml* ./

# Install dependencies using a cache mount
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile || \
    --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install

# Copy source and build
COPY . .
ARG VITE_API_BASE_URL=""
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN pnpm build

# Stage 2: Serve
FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
