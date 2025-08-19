# Multi-stage Dockerfile for Open-SWE deployment
# Builds and runs both the LangGraph agent and Next.js web interface

# Build stage
FROM node:20-alpine AS builder

# Install system dependencies
RUN apk add --no-cache git

# Set working directory
WORKDIR /app

# Install Yarn 3.5.1
RUN corepack enable && corepack prepare yarn@3.5.1 --activate

# Copy workspace configuration files
COPY package.json yarn.lock .yarnrc.yml ./
COPY turbo.json tsconfig.json langgraph.json ./

# Copy all workspace packages
COPY apps/ ./apps/
COPY packages/ ./packages/

# Install all dependencies (including dev dependencies needed for build)
RUN yarn install --immutable

# Build all packages using Turbo orchestration
# Turbo automatically handles the correct build order:
# 1. packages/shared (TypeScript compilation to dist/)
# 2. apps/open-swe (TypeScript compilation to dist/)
# 3. apps/web (Next.js build to .next/)
# This ensures packages/shared is built before other packages consume it
RUN yarn build

# Runtime stage
FROM node:20-alpine AS runtime

# Install system dependencies needed for runtime
RUN apk add --no-cache git

# Set working directory
WORKDIR /app

# Install Yarn 3.5.1
RUN corepack enable && corepack prepare yarn@3.5.1 --activate

# Copy workspace configuration files
COPY package.json yarn.lock .yarnrc.yml ./
COPY turbo.json tsconfig.json langgraph.json ./

# Copy package.json files for all workspaces to maintain structure
COPY apps/open-swe/package.json ./apps/open-swe/
COPY apps/web/package.json ./apps/web/
COPY packages/shared/package.json ./packages/shared/

# Install only production dependencies
RUN yarn workspaces focus --production

# Copy built applications from builder stage
COPY --from=builder /app/packages/shared/dist ./packages/shared/dist
COPY --from=builder /app/apps/open-swe/dist ./apps/open-swe/dist
COPY --from=builder /app/apps/web/.next ./apps/web/.next
COPY --from=builder /app/apps/web/public ./apps/web/public

# Copy source files needed for runtime
COPY --from=builder /app/apps/open-swe/src ./apps/open-swe/src
COPY --from=builder /app/apps/web/next.config.mjs ./apps/web/
COPY --from=builder /app/apps/web/src ./apps/web/src

# Create startup script
RUN cat > /app/start.sh << 'EOF'
#!/bin/sh
set -e

echo "Starting Open-SWE services..."

# Set default environment variables for inter-service communication
export PORT=${PORT:-2024}
export LANGGRAPH_API_URL=${LANGGRAPH_API_URL:-http://localhost:2024}
export NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL:-http://localhost:3000/api}
export OPEN_SWE_APP_URL=${OPEN_SWE_APP_URL:-http://localhost:3000}

# Start LangGraph agent in background
echo "Starting LangGraph agent on port $PORT..."
cd /app/apps/open-swe
npx langgraphjs up --config ../../langgraph.json --port $PORT &
AGENT_PID=$!

# Wait a moment for the agent to start
sleep 5

# Start Next.js web interface
echo "Starting Next.js web interface on port 3000..."
cd /app/apps/web
yarn start &
WEB_PID=$!

# Function to handle shutdown
shutdown() {
    echo "Shutting down services..."
    kill $AGENT_PID $WEB_PID 2>/dev/null || true
    wait $AGENT_PID $WEB_PID 2>/dev/null || true
    exit 0
}

# Set up signal handlers
trap shutdown SIGTERM SIGINT

# Wait for both processes
wait $AGENT_PID $WEB_PID
EOF

# Make startup script executable
RUN chmod +x /app/start.sh

# Expose ports for both services
EXPOSE 2024 3000

# Set default environment variables
ENV NODE_ENV=production
ENV PORT=2024
ENV LANGGRAPH_API_URL=http://localhost:2024
ENV NEXT_PUBLIC_API_URL=http://localhost:3000/api
ENV OPEN_SWE_APP_URL=http://localhost:3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || curl -f http://localhost:2024/health || exit 1

# Start both services
CMD ["/app/start.sh"]


