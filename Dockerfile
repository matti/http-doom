# Stage 1: Build Caddy with CGI plugin
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/aksdb/caddy-cgi/v2

# Stage 2: Runtime
FROM alpine:3.20

RUN apk add --no-cache \
    xvfb \
    imagemagick \
    xdpyinfo \
    xdotool \
    bash \
    curl \
    && apk add --no-cache chocolate-doom \
    --repository http://dl-cdn.alpinelinux.org/alpine/edge/testing

COPY --from=builder /usr/bin/caddy /usr/local/bin/caddy

WORKDIR /app
COPY app .

ENV PORT=8080
ENV DOOM_MAX_SLOTS=4
ENV DOOM_IDLE_TIMEOUT=300

EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
