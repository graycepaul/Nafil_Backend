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


settings = Settings()  # type: ignore[call-arg]
