from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Supabase project — the FastAPI service is a secondary consumer of the
    # same Postgres database and auth users; it never owns the schema.
    supabase_url: str
    supabase_service_role_key: str
    # Only needed as a fallback for legacy HS256-signed tokens (no `kid` in
    # the header) — this project's current session tokens are verified
    # against the JWKS endpoint instead (see app/core/security.py) and don't
    # need this at all.
    supabase_jwt_secret: str = ""

    # Direct Postgres connection (Supabase connection string), used by SQLAlchemy
    # for queries/joins that are impractical through PostgREST/RLS.
    database_url: str

    environment: str = "development"
    cors_origins: list[str] = ["*"]

    # Optional: an Expo access token scopes/authenticates push-send requests
    # to this project specifically. Not required to send push at all — Expo's
    # push API works without it — but recommended once you have an EAS
    # project, so an unrelated app's leaked push tokens can't be used to spam
    # notifications through your account.
    expo_access_token: str = ""

    # Shared secret a Postgres trigger sends back to this service (as the
    # X-Internal-Secret header) when it wants a push sent — see
    # supabase/migrations/0028_generic_push_notifications.sql. Not a user's
    # credential, so it isn't verified against Supabase's JWKS like normal
    # requests; this is the only thing stopping /push/notify-user from being
    # a public "push anything to anyone" endpoint. Must match the value
    # stored in that migration's `vault.create_secret` call exactly.
    internal_push_secret: str = ""


settings = Settings()  # type: ignore[call-arg]
