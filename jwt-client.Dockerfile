FROM alpine:3.21

# Install required tools: bash, curl, jq
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    ca-certificates

WORKDIR /app

# Copy the JWT client script
COPY jwt-client.sh /app/jwt-client.sh
RUN chmod +x /app/jwt-client.sh

# Keep container running
CMD ["tail", "-f", "/dev/null"]
