# Build stage
FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o jwt-provider .

# Runtime stage
FROM alpine:3.22

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /app/jwt-provider .

EXPOSE 8000

CMD ["./jwt-provider"]
