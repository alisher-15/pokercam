# Debian 13 (trixie): mediasoup picks its prebuilt worker by the build host's kernel, and the one for
# kernel 7 (GitHub's runners) needs glibc 2.38 / GLIBCXX_3.4.31, which bookworm (node:24-slim) lacks.
FROM node:24-trixie-slim AS build
WORKDIR /srv
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
COPY web ./web
RUN npm run build && npm prune --omit=dev

FROM node:24-trixie-slim
# SPEC 7.2: FFmpeg remuxes each table's RTP into the DVR's HLS segments. Over IPv4: the build network has no
# IPv6, and on some VPS the mirrors' IPv6 addresses come first and apt gives up on them.
RUN apt-get -o Acquire::ForceIPv4=true update \
    && apt-get -o Acquire::ForceIPv4=true install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production
WORKDIR /srv
COPY package.json ./
COPY --from=build /srv/node_modules ./node_modules
COPY --from=build /srv/dist ./dist
USER node
EXPOSE 3000
CMD ["node", "dist/index.js"]
