# JWT Authentication Demo for Conjur

This demo showcases end-to-end JWT authentication with Conjur Open Source using a real JWT provider.

## Architecture Overview

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  JWT Provider   │         │  Conjur Server  │         │   JWT Client    │
│                 │         │                 │         │                 │
│  Issues JWTs    │◄────────┤  Validates JWT  │◄────────┤  Uses JWT to    │
│  Exposes JWKS   │         │  via JWKS URI   │         │  Authenticate   │
└─────────────────┘         └─────────────────┘         └─────────────────┘
        │                            │                            │
        │                            │                            │
        └────────────────────────────┴────────────────────────────┘
                    Docker Compose Network
```

## Components

1. **JWT Provider** (`jwt-provider/`)
   - Go HTTP server
   - Generates RSA key pairs on startup
   - Exposes JWKS endpoint (`/.well-known/jwks.json`)
   - Issues JWT tokens with custom claims
   - Port: 8000

   > **Demo note:** This provider issues tokens without authentication—anyone can request one. In production, JWT providers (OAuth2/OIDC, Auth0, Okta, etc.) require you to authenticate first (e.g. client credentials, user login, API key) before issuing a token. This demo focuses on how Conjur validates and uses JWTs, not on securing the token issuance.

2. **Conjur Server** (existing)
   - Configured with JWT authenticator
   - Validates JWTs using JWKS from provider
   - Enforces claims and policies
   - Port: 8080 (HTTP), 8443 (HTTPS via proxy)

3. **JWT Client** (custom Alpine image)
   - Bash script demonstrating JWT authentication flow
   - Obtains JWT from provider
   - Authenticates to Conjur
   - Retrieves secrets

## Setup Instructions

### Quick Start (from scratch)

To run the full demo from a clean state:

```bash
./setup-jwt-demo.sh --from-scratch
```

This stops containers, generates keys, starts services, creates the account, configures JWT auth, and runs the demo.

### Manual Setup

#### Step 1: Start the Environment

Follow the standard quickstart setup first:

```bash
# Pull images
docker compose pull

# Generate master key
docker compose run --no-deps --rm conjur data-key generate > data_key

# Set environment variables
export CONJUR_DATA_KEY="$(< data_key)"
export CONJUR_AUTHENTICATORS='authn,authn-jwt/demo'

# Start services (including new JWT provider and client)
docker compose up -d

# Create Conjur account
docker compose exec conjur conjurctl account create myConjurAccount > admin_data
```

### Step 2: Configure the Conjur Client

```bash
# Initialize client connection
docker compose exec client conjur init oss -u https://proxy -a myConjurAccount --self-signed

# Login as admin (use API key from admin_data file)
docker-compose exec client conjur login -i admin -p `cat admin_data | grep "API key for admin:" | rev| cut -d " " -f1 | rev`
```

### Step 3: Load JWT Authentication Policy

```bash
# Load the JWT authenticator policy
docker compose exec client conjur policy load -b root -f /policy/authn-jwt.yml
```

This policy creates:
- JWT authenticator webservice (`conjur/authn-jwt/demo`)
- Application host (`jwt-app/secure-app`)
- Secret variable (`jwt-app/db-password`)
- Appropriate permissions and group memberships

### Step 4: Configure JWT Authenticator Variables

Get the JWT provider's JWKS URI and configure Conjur:

```bash
# Set the JWKS URI (where Conjur fetches public keys)
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/jwks-uri \
  -v "http://jwt-provider:8000/.well-known/jwks.json"

# Set the issuer (must match JWT's "iss" claim)
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/issuer \
  -v "demo-jwt-provider"

# Set token-app-property (maps JWT claim to host ID)
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/token-app-property \
  -v "app-id"

# Set enforced claims (required JWT claims)
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/enforced-claims \
  -v "environment,team"
```

### Step 5: Store a Secret

```bash
# Store a database password that the JWT-authenticated app can retrieve
docker compose exec client conjur variable set \
  -i jwt-app/db-password \
  -v "SuperSecretDatabasePassword123"
```

### Step 6: Verify JWT Authenticator Status

```bash
# Check that the JWT authenticator is properly configured
docker compose exec client bash -c 'conjur authenticate > /tmp/token && TOKEN=$(cat /tmp/token | base64 | tr -d "\r\n") && curl -k -s -H "Authorization: Token token=\"$TOKEN\"" https://proxy/authn-jwt/demo/myConjurAccount/status'
```

Expected output should show `"status": "ok"` or similar success message.

## Running the Demo

### Test the JWT Provider

```bash
# Check JWT provider health
curl http://localhost:8000/health | jq

# View JWKS (public keys)
curl http://localhost:8000/.well-known/jwks.json | jq

# Issue a test JWT
curl "http://localhost:8000/issue-token?app-id=secure-app&environment=production&team=platform" | jq
```

### Run the JWT Client Demo

**Option 1: Run the steps inline**

```bash
APP_ID="secure-app"

# Step 1: Obtain JWT from provider
JWT_TOKEN=$(curl -s "http://localhost:8000/issue-token?app-id=${APP_ID}&environment=production&team=platform" | jq -r '.token')
echo "$JWT_TOKEN" | cut -d. -f2 | awk '{s=$0; while(length(s)%4) s=s"="; print s}' | base64 -d 2>/dev/null | jq

# Step 2: Authenticate to Conjur using JWT
CONJUR_TOKEN=$(curl -k -s --request POST \
  'https://localhost:8443/authn-jwt/demo/myConjurAccount/authenticate' \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --header 'Accept-Encoding: base64' \
  --data-urlencode "jwt=${JWT_TOKEN}")
echo "$CONJUR_TOKEN" | cut -d. -f2 | awk '{s=$0; while(length(s)%4) s=s"="; print s}' | base64 -d 2>/dev/null | jq

# Step 3: Retrieve secret using Conjur token
curl -k -s \
  --header "Authorization: Token token=\"${CONJUR_TOKEN}\"" \
  'https://localhost:8443/secrets/myConjurAccount/variable/jwt-app/db-password'
```

**Option 2: Run the script**

```bash
# Execute the JWT authentication flow (app-id is required)
docker compose exec jwt-client /app/jwt-client.sh secure-app

# Or use a different app-id (must exist in Conjur policy)
docker compose exec jwt-client /app/jwt-client.sh my-other-app
```

Try changing the app-id (e.g. `APP_ID="my-other-app"` for Option 1, or pass a different argument for Option 2) and run again. It should fail—Conjur only accepts app-ids that exist in the policy. This demonstrates that identity is enforced; to succeed with a different app-id, you must first add the host to the policy.

The script will:
1. Obtain a JWT from the provider with claims:
   - `app-id`: the app-id passed as argument
   - `environment`: production
   - `team`: platform
2. Authenticate to Conjur using the JWT
3. Retrieve the secret `jwt-app/db-password`
4. Display the secret value

Expected output:
```
========================================
JWT Authentication Demo
========================================

Step 1: Obtain JWT from provider...
✓ JWT obtained successfully
Token (first 50 chars): eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6Ij...

Step 2: Authenticate to Conjur using JWT...
✓ Authenticated successfully!
Conjur token (first 50 chars): eyJwcm90ZWN0ZWQiOiJleUpoYkdjaU9pSmpiMjVxZFhJ...

Step 3: Retrieve secret using Conjur token...
✓ Secret retrieved successfully!
Secret value: SuperSecretDatabasePassword123

========================================
JWT Authentication Demo Complete!
========================================
```

## Understanding the Flow

### JWT Claims

The JWT provider issues tokens with these claims:

```json
{
  "app-id": "secure-app",
  "environment": "production",
  "team": "platform",
  "iat": 1234567890,
  "exp": 1234571490,
  "iss": "demo-jwt-provider"
}
```

### Policy Mapping

- `token-app-property: "app-id"` → Maps JWT claim `app-id` to Conjur host ID
- JWT with `"app-id": "secure-app"` → Authenticates as `host/jwt-app/secure-app`
- `enforced-claims: "environment,team"` → JWT must contain both claims

### Authentication Endpoint

```
POST https://proxy/authn-jwt/demo/myConjurAccount/authenticate
Content-Type: application/x-www-form-urlencoded
Accept-Encoding: base64

jwt=<your-jwt-token>
```

## Policy Structure

The policy (`conf/policy/authn-jwt.yml`) defines:

```yaml
conjur/authn-jwt/demo/          # JWT authenticator service
├── webservice                  # Authentication endpoint
├── variables
│   ├── jwks-uri               # Where to fetch public keys
│   ├── issuer                 # Expected JWT issuer
│   ├── token-app-property     # JWT claim for identity mapping
│   └── enforced-claims        # Required JWT claims
├── groups
│   ├── apps                   # Apps allowed to authenticate
│   └── operators              # Users who can check status
└── status                     # Status check webservice

jwt-app/                       # Application using JWT auth
├── host/secure-app           # Host identity (maps to JWT app-id)
└── variable/db-password      # Secret accessible by the host
```

## Troubleshooting

### Check JWT Provider

```bash
# View provider info
curl http://localhost:8000/

# Check JWKS format
curl http://localhost:8000/.well-known/jwks.json | jq
```

### Verify Conjur Configuration

```bash
# Check authenticator is enabled
docker compose exec conjur printenv CONJUR_AUTHENTICATORS

# Verify JWKS URI is set
docker compose exec client conjur variable get \
  -i conjur/authn-jwt/demo/jwks-uri

# Check authenticator status (Method 1: Single command)
docker compose exec client bash -c 'conjur authenticate > /tmp/token && TOKEN=$(cat /tmp/token | base64 | tr -d "\r\n") && curl -k -s -H "Authorization: Token token=\"$TOKEN\"" https://proxy/authn-jwt/demo/myConjurAccount/status'

# Check authenticator status (Method 2: Two-step approach)
docker compose exec client conjur authenticate > /tmp/token
docker compose exec client bash -c 'TOKEN=$(cat /tmp/token | base64 | tr -d "\r\n") && curl -k -H "Authorization: Token token=\"$TOKEN\"" https://proxy/authn-jwt/demo/myConjurAccount/status'
```

### Decode JWT Manually

```bash
# Issue a token
TOKEN=$(curl -s "http://localhost:8000/issue-token" | jq -r '.token')

# Decode header
echo $TOKEN | cut -d'.' -f1 | awk '{s=$0; while(length(s)%4) s=s"="; print s}' | base64 -d | jq

# Decode payload
echo $TOKEN | cut -d'.' -f2 | awk '{s=$0; while(length(s)%4) s=s"="; print s}' | base64 -d | jq
```

### Test Authentication Manually

```bash
# Get a JWT
JWT=$(curl -s "http://localhost:8000/issue-token?app-id=secure-app" | jq -r '.token')

# Authenticate to Conjur
curl -k --request POST \
  'https://localhost:8443/authn-jwt/demo/myConjurAccount/authenticate' \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --header 'Accept-Encoding: base64' \
  --data-urlencode "jwt=${JWT}"
```

### Common Issues

1. **"Authentication failed"**
   - Verify JWKS URI is accessible from Conjur container
   - Check issuer matches between JWT and Conjur configuration
   - Ensure enforced claims are present in JWT

2. **"Failed to retrieve secret"**
   - Verify host has permission to read the secret
   - Check that host is member of `conjur/authn-jwt/demo/apps` group

3. **"JWKS endpoint not found"**
   - Ensure jwt-provider container is running
   - Check network connectivity: `docker compose exec conjur curl http://jwt-provider:8000/health`

## Advanced Configuration

### Custom JWT Claims

Modify the JWT provider to issue different claims:

```bash
# Issue JWT with custom app-id
curl "http://localhost:8000/issue-token?app-id=my-other-app&environment=staging&team=devops"
```

Then create a corresponding host in Conjur policy.

### Multiple Authenticators

You can configure multiple JWT authenticators for different providers:

```yaml
- !policy
  id: conjur/authn-jwt/gitlab
  # ... configuration for GitLab

- !policy
  id: conjur/authn-jwt/github
  # ... configuration for GitHub Actions
```

### Static Public Keys

Instead of JWKS URI, use static public keys:

```bash
docker compose exec client conjur variable set \
  -i conjur/authn-jwt/demo/public-keys \
  -v '{"type":"jwks", "value":{"keys":[...]}}'
```

## Cleanup

```bash
# Stop all containers
docker compose down

# Remove volumes (optional)
docker compose down -v
```

## References

- [Conjur JWT Authentication Documentation](https://docs.cyberark.com/secrets-manager-sh/latest/en/content/operations/services/cjr-authn-jwt.htm)
- [JWT RFC 7519](https://datatracker.ietf.org/doc/html/rfc7519)
- [JWK Set RFC 7517](https://datatracker.ietf.org/doc/html/rfc7517)
- [Conjur Policy Reference](https://docs.cyberark.com/conjur-open-source/Latest/en/Content/Operations/Policy/policy-statement-ref.htm)
