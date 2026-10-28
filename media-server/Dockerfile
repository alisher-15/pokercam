FROM node:24-slim AS build
WORKDIR /srv
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-slim
ENV NODE_ENV=production
WORKDIR /srv
COPY package.json ./
COPY --from=build /srv/node_modules ./node_modules
COPY --from=build /srv/dist ./dist
USER node
EXPOSE 3000
CMD ["node", "dist/index.js"]
