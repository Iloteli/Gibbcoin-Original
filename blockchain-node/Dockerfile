FROM node:22-alpine
WORKDIR /app
COPY app/lib/blockchain-core.js app/lib/blockchain-core.js
COPY blockchain-node blockchain-node
ENV PORT=8787
EXPOSE 8787
VOLUME ["/app/blockchain-node/data"]
CMD ["node", "blockchain-node/server.mjs"]
