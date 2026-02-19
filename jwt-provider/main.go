package main

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/lestrrat-go/jwx/v2/jwk"
)

const (
	port    = "8000"
	issuer  = "demo-jwt-provider"
	keySize = 2048
)

var (
	privateKey *rsa.PrivateKey
	publicKey  *rsa.PublicKey
	keyID      string
	jwksJSON   []byte
)

func main() {
	if err := generateKeys(); err != nil {
		log.Fatalf("Failed to initialize JWT provider: %v", err)
	}

	http.HandleFunc("/", rootHandler)
	http.HandleFunc("/.well-known/jwks.json", jwksHandler)
	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/issue-token", issueTokenHandler)

	addr := "0.0.0.0:" + port
	log.Printf("JWT Provider listening on port %s", port)
	log.Printf("JWKS endpoint: http://localhost:%s/.well-known/jwks.json", port)
	log.Printf("Issue token: http://localhost:%s/issue-token", port)

	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func generateKeys() error {
	log.Println("Generating RSA key pair...")

	key, err := rsa.GenerateKey(rand.Reader, keySize)
	if err != nil {
		return err
	}

	privateKey = key
	publicKey = &key.PublicKey

	// Generate key ID
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return err
	}
	keyID = hex.EncodeToString(b)

	// Create JWKS from public key
	jwkKey, err := jwk.FromRaw(publicKey)
	if err != nil {
		return err
	}
	_ = jwkKey.Set(jwk.KeyIDKey, keyID)
	_ = jwkKey.Set(jwk.AlgorithmKey, "RS256")
	_ = jwkKey.Set("use", "sig")

	jwks := jwk.NewSet()
	jwks.AddKey(jwkKey)

	jwksJSON, err = json.Marshal(jwks)
	if err != nil {
		return err
	}

	log.Println("Keys generated successfully")
	log.Println("Key ID:", keyID)
	return nil
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"message": "JWT Provider Demo Service",
		"endpoints": map[string]string{
			"jwks":       "/.well-known/jwks.json",
			"issueToken": "/issue-token?app-id=secure-app&environment=production&team=platform",
			"health":     "/health",
		},
		"issuer": issuer,
		"keyId":  keyID,
	})
}

func jwksHandler(w http.ResponseWriter, r *http.Request) {
	log.Println("JWKS endpoint called")
	w.Header().Set("Content-Type", "application/json")
	w.Write(jwksJSON)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "healthy",
		"keyId":  keyID,
	})
}

func issueTokenHandler(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	appID := q.Get("app-id")
	if appID == "" {
		appID = "secure-app"
	}
	environment := q.Get("environment")
	if environment == "" {
		environment = "production"
	}
	team := q.Get("team")
	if team == "" {
		team = "platform"
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"app-id":     appID,
		"environment": environment,
		"team":       team,
		"iat":        now.Unix(),
		"exp":        now.Add(time.Hour).Unix(),
		"iss":        issuer,
	}

	token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	token.Header["kid"] = keyID

	tokenString, err := token.SignedString(privateKey)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	log.Printf("Issued JWT for app-id: %s", appID)
	log.Printf("Token payload: app-id=%s environment=%s team=%s", appID, environment, team)

	// Decode for response (header + payload only, no verification needed)
	decoded, _, _ := jwt.NewParser().ParseUnverified(tokenString, jwt.MapClaims{})
	resp := map[string]any{"token": tokenString}
	if decoded != nil {
		resp["decoded"] = map[string]any{
			"header":  decoded.Header,
			"payload": decoded.Claims,
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
