#!/bin/bash

set -e

echo "========================================"
echo "JWT Authentication Demo"
echo "========================================"
echo

# Configuration
JWT_PROVIDER="http://jwt-provider:8000"
CONJUR_URL="https://proxy"
CONJUR_ACCOUNT="myConjurAccount"

if [ -z "$1" ]; then
  echo "Usage: $0 <app-id>"
  echo "Example: $0 secure-app"
  exit 1
fi
APP_ID="$1"

echo "Step 1: Obtain JWT from provider..."
JWT_RESPONSE=$(curl -s "${JWT_PROVIDER}/issue-token?app-id=${APP_ID}&environment=production&team=platform")
JWT_TOKEN=$(echo $JWT_RESPONSE | jq -r '.token')

if [ -z "$JWT_TOKEN" ] || [ "$JWT_TOKEN" = "null" ]; then
  echo "ERROR: Failed to obtain JWT token"
  echo "Response: $JWT_RESPONSE"
  exit 1
fi

echo "✓ JWT obtained successfully"
echo "Token (first 50 chars): ${JWT_TOKEN:0:50}..."
echo

echo "Step 2: Authenticate to Conjur using JWT..."
AUTH_RESPONSE=$(curl -k -s -w "\n%{http_code}" \
  --request POST \
  "${CONJUR_URL}/authn-jwt/demo/${CONJUR_ACCOUNT}/authenticate" \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --header 'Accept-Encoding: base64' \
  --data-urlencode "jwt=${JWT_TOKEN}")

# Extract HTTP status code and response body
HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
CONJUR_TOKEN=$(echo "$AUTH_RESPONSE" | head -n1)

if [ "$HTTP_CODE" != "200" ]; then
  echo "ERROR: Authentication failed with status $HTTP_CODE"
  echo "Response: $CONJUR_TOKEN"
  exit 1
fi

echo "✓ Authenticated successfully!"
echo "Conjur token (first 50 chars): ${CONJUR_TOKEN:0:50}..."
echo

echo "Step 3: Retrieve secret using Conjur token..."
SECRET=$(curl -k -s \
  --header "Authorization: Token token=\"${CONJUR_TOKEN}\"" \
  "${CONJUR_URL}/secrets/${CONJUR_ACCOUNT}/variable/jwt-app/db-password")

if [ -z "$SECRET" ]; then
  echo "ERROR: Failed to retrieve secret"
  exit 1
fi

echo "✓ Secret retrieved successfully!"
echo "Secret value: $SECRET"
echo

echo "========================================"
echo "JWT Authentication Demo Complete!"
echo "========================================"
echo
echo "Summary:"
echo "1. Obtained JWT from provider with app-id: ${APP_ID}"
echo "2. Authenticated to Conjur using JWT"
echo "3. Retrieved secret: jwt-app/db-password"
echo
