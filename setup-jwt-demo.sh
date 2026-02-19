#!/bin/bash

set -e

cd "$(dirname "$0")"

FROM_SCRATCH=false
RUN_DEMO=false
for arg in "$@"; do
  case $arg in
    --from-scratch|-f) FROM_SCRATCH=true ;;
    --run-demo|-r)    RUN_DEMO=true ;;
    -h|--help)        echo "Usage: $0 [--from-scratch|-f] [--run-demo|-r]"; exit 0 ;;
    *)                echo "Unknown option: $arg"; echo "Usage: $0 [--from-scratch|-f] [--run-demo|-r]"; exit 1 ;;
  esac
done

echo "========================================"
echo "JWT Authentication Demo Setup"
echo "========================================"
echo

if [ "$FROM_SCRATCH" = true ]; then
  echo "Running full setup from scratch..."
  echo

  echo "Step 0a: Stopping all containers..."
  docker compose down
  echo

  echo "Step 0b: Generating Conjur data key..."
  docker compose run --no-deps --rm conjur data-key generate > data_key
  export CONJUR_DATA_KEY="$(< data_key)"
  export CONJUR_AUTHENTICATORS='authn,authn-jwt/demo'
  echo "✓ Data key generated"
  echo

  echo "Step 0c: Starting all services..."
  docker compose up -d
  echo

  echo "Step 0d: Waiting for Conjur to be ready..."
  MAX_RETRIES=60
  for i in $(seq 1 $MAX_RETRIES); do
    if docker compose exec conjur curl -s http://localhost/health > /dev/null 2>&1; then
      echo "✓ Conjur is ready"
      break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
      echo "ERROR: Conjur failed to start"
      exit 1
    fi
    echo "  Waiting... ($i/$MAX_RETRIES)"
    sleep 2
  done
  echo

  echo "Step 0e: Creating Conjur account..."
  docker compose exec conjur conjurctl account create myConjurAccount > admin_data
  echo "✓ Account created"
  echo
else
  # Check if data_key exists
  if [ ! -f data_key ]; then
    echo "ERROR: data_key file not found!"
    echo "Run with --from-scratch for full setup: $0 --from-scratch"
    exit 1
  fi

  # Check if CONJUR_DATA_KEY is set
  if [ -z "$CONJUR_DATA_KEY" ]; then
    export CONJUR_DATA_KEY="$(< data_key)"
  fi

  if [ -z "$CONJUR_AUTHENTICATORS" ]; then
    export CONJUR_AUTHENTICATORS='authn,authn-jwt/demo'
  fi

  # Check if admin_data exists
  if [ ! -f admin_data ]; then
    echo "ERROR: admin_data file not found!"
    echo "Create account first: docker compose exec conjur conjurctl account create myConjurAccount > admin_data"
    echo "Or run with --from-scratch for full setup: $0 --from-scratch"
    exit 1
  fi

  # Check containers are running
  if ! docker compose ps | grep -qE "conjur_server.*Up"; then
    echo "ERROR: Conjur server is not running!"
    echo "Start: docker compose up -d"
    echo "Or run with --from-scratch for full setup: $0 --from-scratch"
    exit 1
  fi

  if ! docker compose ps | grep -qE "jwt_provider.*Up"; then
    echo "ERROR: JWT provider is not running!"
    echo "Start: docker compose up -d"
    exit 1
  fi

  echo "✓ Prerequisites OK"
  echo
fi

echo "Step 1: Checking JWT authenticator configuration..."
CURRENT_AUTHENTICATORS="${CONJUR_AUTHENTICATORS:-}"
REQUIRED_AUTHENTICATORS="authn,authn-jwt/demo"

if [ "$CURRENT_AUTHENTICATORS" != "$REQUIRED_AUTHENTICATORS" ]; then
  echo "ERROR: CONJUR_AUTHENTICATORS is not set correctly!"
  echo "Current value: ${CURRENT_AUTHENTICATORS:-<not set>}"
  echo "Required value: $REQUIRED_AUTHENTICATORS"
  echo
  echo "Run: export CONJUR_AUTHENTICATORS='$REQUIRED_AUTHENTICATORS'"
  echo "Then: docker compose down conjur && docker compose up -d conjur"
  exit 1
fi
echo "✓ CONJUR_AUTHENTICATORS correctly configured"
echo

echo "Step 2: Waiting for Conjur to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
until docker compose exec conjur curl -s http://localhost/health > /dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT+1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "ERROR: Conjur failed to start after $MAX_RETRIES attempts"
    exit 1
  fi
  echo "Waiting for Conjur... ($RETRY_COUNT/$MAX_RETRIES)"
  sleep 2
done
echo "✓ Conjur is ready"
echo

echo "Step 3: Initializing Conjur client..."
docker compose exec client conjur init oss -u https://proxy -a myConjurAccount --self-signed --force
echo "✓ Client initialized"
echo

echo "Step 4: Logging in as admin..."
ADMIN_API_KEY=$(grep "API key for admin" admin_data | awk '{print $NF}')
if [ -z "$ADMIN_API_KEY" ]; then
  ADMIN_API_KEY=$(tail -1 admin_data)
fi
docker compose exec -T client conjur login -i admin -p "$ADMIN_API_KEY"
echo "✓ Logged in as admin"
echo

echo "Step 5: Loading JWT authentication policy..."
docker compose exec client conjur policy load -b root -f /policy/authn-jwt.yml
echo "✓ Policy loaded"
echo

echo "Step 6: Configuring JWT authenticator variables..."
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/jwks-uri \
  -v "http://jwt-provider:8000/.well-known/jwks.json"
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/issuer \
  -v "demo-jwt-provider"
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/token-app-property \
  -v "app-id"
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/enforced-claims \
  -v "environment,team"
echo "✓ JWT authenticator configured"
echo

echo "Step 7: Storing demo secret..."
docker compose exec client conjur variable set \
  -i jwt-app/db-password \
  -v "SuperSecretDatabasePassword123"
echo "✓ Secret stored"
echo

echo "Step 8: Verifying JWT authenticator status..."
docker compose exec -T client conjur login -i admin -p "$ADMIN_API_KEY" > /dev/null 2>&1
STATUS_RESPONSE=$(docker compose exec -T client bash -c 'conjur authenticate > /tmp/token && TOKEN=$(cat /tmp/token | base64 | tr -d "\r\n") && curl -k -s -H "Authorization: Token token=\"$TOKEN\"" https://proxy/authn-jwt/demo/myConjurAccount/status')
echo "Authenticator status: $STATUS_RESPONSE"
echo

echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo
echo "To run the demo:"
echo "  docker compose exec jwt-client /app/jwt-client.sh <app-id>"
echo
echo "To test the JWT provider:"
echo "  curl http://localhost:8000/health"
echo "  curl http://localhost:8000/.well-known/jwks.json"
echo "  curl 'http://localhost:8000/issue-token?app-id=secure-app'"
echo

if [ "$RUN_DEMO" = true ] || [ "$FROM_SCRATCH" = true ]; then
  echo "Running JWT client demo..."
  docker compose exec jwt-client /app/jwt-client.sh secure-app
  echo
fi

echo "For more information, see JWT_AUTHENTICATION_DEMO.md"
echo
