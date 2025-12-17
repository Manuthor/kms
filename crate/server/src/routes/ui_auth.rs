use std::collections::HashMap;

use actix_session::Session;
use actix_web::{HttpRequest, HttpResponse, get, web};
use alcoholic_jwt::{JWKS, token_kid};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::config::OidcConfig;

#[get("/login_flow")]
pub(crate) async fn login(
    session: Session,
    oidc_config: web::Data<OidcConfig>,
    kms_url: web::Data<String>,
) -> HttpResponse {
    // Build discovery URL
    let issuer = match &oidc_config.ui_oidc_issuer_url {
        Some(url) => url.clone(),
        None => return HttpResponse::InternalServerError().body("Issuer URL is missing"),
    };

    let discovery_url = if issuer.ends_with('/') {
        format!("{issuer}.well-known/openid-configuration")
    } else {
        format!("{issuer}/.well-known/openid-configuration")
    };

    let Ok(client) = reqwest::ClientBuilder::new().build() else {
        return HttpResponse::InternalServerError().body("Failed to build HTTP client");
    };

    // Fetch provider metadata
    let provider = match client.get(&discovery_url).send().await {
        Ok(resp) => match resp.json::<OidcProvider>().await {
            Ok(p) => p,
            Err(err) => {
                return HttpResponse::InternalServerError()
                    .body(format!("Failed to parse provider metadata: {err}"));
            }
        },
        Err(err) => {
            return HttpResponse::InternalServerError()
                .body(format!("Failed to fetch provider metadata: {err}"));
        }
    };

    let Ok(redirect_url) = Url::parse(&format!("{}/ui/callback", kms_url.as_str())) else {
        return HttpResponse::InternalServerError().body("Invalid Redirect URL");
    };

    let client_id = match &oidc_config.ui_oidc_client_id {
        Some(id) => id.clone(),
        None => return HttpResponse::InternalServerError().body("Client ID is missing"),
    };

    // Generate PKCE values
    let pkce_verifier = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(pkce_verifier.as_bytes()));

    // CSRF state and nonce
    let csrf_token = Uuid::new_v4().to_string();
    let nonce = Uuid::new_v4().to_string();

    // Build auth URL
    let Ok(mut auth_url) = Url::parse(&provider.authorization_endpoint) else {
        return HttpResponse::InternalServerError().body("Invalid authorization endpoint");
    };
    auth_url
        .query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", &client_id)
        .append_pair("redirect_uri", redirect_url.as_str())
        .append_pair("scope", "openid email")
        .append_pair("state", &csrf_token)
        .append_pair("nonce", &nonce)
        .append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256");

    if let Err(e) = session.insert("pkce_verifier", pkce_verifier) {
        return HttpResponse::InternalServerError()
            .body(format!("Failed to insert pkce_verifier: {e:?}"));
    }
    if let Err(e) = session.insert("csrf_token", &csrf_token) {
        return HttpResponse::InternalServerError()
            .body(format!("Failed to insert csrf_token: {e:?}"));
    }
    if let Err(e) = session.insert("nonce", &nonce) {
        return HttpResponse::InternalServerError().body(format!("Failed to insert nonce: {e:?}"));
    }
    // Store discovery-derived endpoints we need in callback
    drop(session.insert("_oidc_token_endpoint", &provider.token_endpoint));
    drop(session.insert("_oidc_jwks_uri", &provider.jwks_uri));

    // Redirect to Identity Provider
    HttpResponse::Found()
        .append_header(("Location", auth_url.to_string()))
        .finish()
}

#[get("/callback")]
pub(crate) async fn callback(
    req: HttpRequest,
    session: Session,
    oidc_config: web::Data<OidcConfig>,
    kms_url: web::Data<String>,
) -> HttpResponse {
    let Ok(query) = web::Query::<HashMap<String, String>>::from_query(req.query_string()) else {
        return HttpResponse::BadRequest().body("Invalid query parameters");
    };

    // Retrieve stored values
    let stored_pkce_verifier = match session.get::<String>("pkce_verifier") {
        Ok(Some(v)) => Some(v),
        Ok(None) => return HttpResponse::BadRequest().body("Missing PKCE verifier"),
        Err(e) => {
            return HttpResponse::InternalServerError()
                .body(format!("Failed to retrieve PKCE verifier: {e}"));
        }
    };

    let stored_csrf_token = match session.get::<String>("csrf_token") {
        Ok(Some(csrf_token)) => Some(csrf_token),
        Ok(None) => return HttpResponse::BadRequest().body("Missing CSRF token"),
        Err(e) => {
            return HttpResponse::InternalServerError()
                .body(format!("Failed to retrieve CSRF token: {e}"));
        }
    };

    let stored_nonce = match session.get::<String>("nonce") {
        Ok(Some(nonce)) => nonce,
        Ok(None) => return HttpResponse::BadRequest().body("Missing nonce"),
        Err(e) => {
            return HttpResponse::InternalServerError()
                .body(format!("Failed to retrieve nonce: {e}"));
        }
    };

    // Validate CSRF token
    let Some(received_csrf_token) = query.get("state") else {
        return HttpResponse::BadRequest().body("Missing state parameter");
    };
    if Some(received_csrf_token) != stored_csrf_token.as_ref() {
        return HttpResponse::BadRequest().body("CSRF token mismatch");
    }

    // Extract authorization code
    let auth_code = match query.get("code") {
        Some(code) => code.to_owned(),
        None => return HttpResponse::BadRequest().body("Missing authorization code"),
    };

    // Retrieve provider endpoints from session (set during login)
    let token_endpoint: String = match session.get("_oidc_token_endpoint") {
        Ok(Some(u)) => u,
        _ => return HttpResponse::InternalServerError().body("Missing token endpoint in session"),
    };
    let jwks_uri: String = match session.get("_oidc_jwks_uri") {
        Ok(Some(u)) => u,
        _ => return HttpResponse::InternalServerError().body("Missing JWKS URI in session"),
    };

    let redirect_url = format!("{}/ui/callback", kms_url.as_str());
    let client_id = match &oidc_config.ui_oidc_client_id {
        Some(id) => id.clone(),
        None => return HttpResponse::InternalServerError().body("Client ID is missing"),
    };

    let Ok(client) = reqwest::ClientBuilder::new().build() else {
        return HttpResponse::InternalServerError().body("Failed to build HTTP client");
    };

    // Prepare token request
    let mut form = vec![
        ("grant_type", "authorization_code".to_owned()),
        ("code", auth_code),
        ("redirect_uri", redirect_url),
        ("client_id", client_id.clone()),
        ("code_verifier", stored_pkce_verifier.unwrap_or_default()),
    ];
    if let Some(secret) = &oidc_config.ui_oidc_client_secret {
        form.push(("client_secret", secret.clone()));
    }

    let token_resp = match client.post(&token_endpoint).form(&form).send().await {
        Ok(r) => r,
        Err(e) => {
            return HttpResponse::InternalServerError()
                .body(format!("Failed to request token: {e}"));
        }
    };
    let token_json = match token_resp.json::<serde_json::Value>().await {
        Ok(v) => v,
        Err(e) => {
            return HttpResponse::InternalServerError()
                .body(format!("Failed to parse token response: {e}"));
        }
    };
    let Some(id_token_str) = token_json.get("id_token").and_then(|v| v.as_str()) else {
        return HttpResponse::InternalServerError().json(serde_json::json!({
            "error": "Error getting id_token"
        }));
    };

    // Verify ID token using JWKS
    let jwks = match client.get(&jwks_uri).send().await {
        Ok(r) => match r.json::<JWKS>().await {
            Ok(j) => j,
            Err(e) => {
                return HttpResponse::InternalServerError()
                    .body(format!("Failed to parse JWKS: {e}"));
            }
        },
        Err(e) => {
            return HttpResponse::InternalServerError().body(format!("Failed to fetch JWKS: {e}"));
        }
    };

    let Ok(Some(kid)) = token_kid(id_token_str) else {
        return HttpResponse::InternalServerError().json(serde_json::json!({
            "error": "No 'kid' in id_token"
        }));
    };
    let Some(jwk) = jwks.find(&kid) else {
        return HttpResponse::InternalServerError().json(serde_json::json!({
            "error": "Signing key not found in JWKS"
        }));
    };

    // Validate signature and required claims presence
    let validations = vec![alcoholic_jwt::Validation::SubjectPresent];
    let valid = match alcoholic_jwt::validate(id_token_str, jwk, validations) {
        Ok(v) => v,
        Err(_e) => {
            return HttpResponse::InternalServerError().json(serde_json::json!({
                "error": "Failed to verify id_token signature"
            }));
        }
    };
    // Check nonce
    if valid
        .claims
        .get("nonce")
        .and_then(|v| v.as_str())
        .is_none_or(|n| n != stored_nonce)
    {
        return HttpResponse::BadRequest().body("Nonce mismatch");
    }

    // Extract email if present
    let user_id = valid
        .claims
        .get("email")
        .and_then(|v| v.as_str())
        .map(str::to_owned);

    if session.insert("id_token", id_token_str).is_err() {
        return HttpResponse::InternalServerError().json(serde_json::json!({
            "error": "Failed to store id_token"
        }));
    }
    if let Some(user_email) = user_id {
        if session.insert("user_id", user_email).is_err() {
            return HttpResponse::InternalServerError().json(serde_json::json!({
                "error": "Failed to store user_id"
            }));
        }
    }

    HttpResponse::Found()
        .append_header(("Location", "/ui/locate"))
        .finish()
}

#[get("/token")]
pub(crate) async fn token(session: Session) -> HttpResponse {
    // Retrieve id_token and user_id from session
    match (
        session.get::<String>("id_token"),
        session.get::<String>("user_id"),
    ) {
        (Ok(Some(id_token)), Ok(Some(user_id))) => HttpResponse::Ok().json(serde_json::json!({
            "id_token": id_token,
            "user_id": user_id,
        })),
        (Ok(None), _) | (_, Ok(None)) => HttpResponse::Unauthorized().json(serde_json::json!({
            "error": "No ID token or user ID found"
        })),
        _ => HttpResponse::InternalServerError().json(serde_json::json!({
            "error": "Failed to retrieve session data"
        })),
    }
}

#[get("/logout")]
pub(crate) async fn logout(
    session: Session,
    oidc_config: web::Data<OidcConfig>,
    kms_url: web::Data<String>,
) -> HttpResponse {
    session.purge();

    let Some(url) = &oidc_config.ui_oidc_logout_url else {
        return HttpResponse::InternalServerError().body("Logout URL is missing");
    };
    let mut logout_url = match Url::parse(url) {
        Ok(parsed_url) => parsed_url,
        Err(e) => {
            return HttpResponse::InternalServerError().body(format!("Invalid logout URL: {e}"));
        }
    };

    let client_id = match &oidc_config.ui_oidc_client_id {
        Some(id) => id.clone(),
        None => return HttpResponse::InternalServerError().body("Client ID is missing"),
    };

    let redirect_url = format!("{}/ui/login", kms_url.as_str());

    logout_url
        .query_pairs_mut()
        .append_pair("client_id", &client_id)
        .append_pair("returnTo", &redirect_url);

    HttpResponse::Found()
        .append_header(("Location", logout_url.to_string()))
        .finish()
}

#[get("/auth_method")]
pub(crate) async fn get_auth_method(auth_type: web::Data<Option<String>>) -> HttpResponse {
    let auth_method = auth_type
        .as_ref()
        .as_ref()
        .map_or_else(|| "None".to_owned(), std::clone::Clone::clone);

    HttpResponse::Ok().json(serde_json::json!({ "auth_method": auth_method }))
}

// Function to register all auth routes
pub fn configure_auth_routes(cfg: &mut web::ServiceConfig) {
    cfg.service(login)
        .service(callback)
        .service(token)
        .service(logout)
        .service(get_auth_method);
}

#[derive(Debug, Deserialize)]
struct OidcProvider {
    authorization_endpoint: String,
    token_endpoint: String,
    jwks_uri: String,
}
