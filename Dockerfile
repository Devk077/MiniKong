# Stage 1: build both binaries
FROM golang:1.25-alpine AS builder

WORKDIR /build

# Download deps first — this layer is cached as long as go.mod/go.sum don't change
COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o /gateway    ./cmd/gateway
RUN CGO_ENABLED=0 GOOS=linux go build -o /mockserver ./cmd/mockserver

# Stage 2: minimal runtime image (~15 MB total)
FROM alpine:latest

COPY --from=builder /gateway    /gateway
COPY --from=builder /mockserver /mockserver
COPY config/ /config/

EXPOSE 8080 9090 2112

CMD ["/gateway", "/config/gateway-docker.yaml"]
