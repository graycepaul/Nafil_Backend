import time
from dataclasses import dataclass
from typing import Any

import httpx
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.db import get_db
from app.models.models import Profile

bearer_scheme = HTTPBearer()

_JWKS_TTL_SECONDS = 3600
_jwks_cache: dict[str, Any] = {"keys": [], "fetched_at": 0.0}


@dataclass
class CurrentUser:
    id: str
    email: str | None
    role: str | None  # profiles.role — looked up from the DB, never trusted from the token
    estate_id: str | None


def _fetch_jwks() -> list[dict]:
    now = time.time()
    if now - _jwks_cache["fetched_at"] > _JWKS_TTL_SECONDS or not _jwks_cache["keys"]:
        resp = httpx.get(
            f"{settings.supabase_url}/auth/v1/.well-known/jwks.json",
            timeout=5,
        )
        resp.raise_for_status()
        _jwks_cache["keys"] = resp.json().get("keys", [])
        _jwks_cache["fetched_at"] = now
    return _jwks_cache["keys"]


def decode_supabase_jwt(token: str) -> dict:
    """
    Supabase Auth signs session tokens one of two ways depending on the
    project's JWT signing-key setup: the legacy shared HS256 secret, or (for
    projects on the newer signing-keys system — this one included) an
    asymmetric key published at the project's JWKS endpoint. A token signed
    the second way has no relationship to `SUPABASE_JWT_SECRET` at all, so
    verifying every token against that one shared secret rejects every real
    user — this picks the right verification path per-token instead of
    assuming one.
    """
    try:
        header = jwt.get_unverified_header(token)
    except JWTError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        ) from exc

    kid = header.get("kid")
    alg = header.get("alg", "HS256")

    try:
        if kid:
            matching_key = next((k for k in _fetch_jwks() if k.get("kid") == kid), None)
            if matching_key is None:
                raise JWTError(f"No JWKS key found for kid={kid}")
            return jwt.decode(
                token,
                matching_key,
                algorithms=[matching_key.get("alg", alg)],
                audience="authenticated",
            )

        if not settings.supabase_jwt_secret:
            raise JWTError("Token has no kid (legacy HS256 format) but SUPABASE_JWT_SECRET is unset")
        return jwt.decode(
            token,
            settings.supabase_jwt_secret,
            algorithms=["HS256"],
            audience="authenticated",
        )
    except (JWTError, httpx.HTTPError) as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        ) from exc


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    db: Session = Depends(get_db),
) -> CurrentUser:
    payload = decode_supabase_jwt(credentials.credentials)
    user_id = payload["sub"]

    # The role that actually governs access (resident/security/admin/
    # super_admin) lives in `profiles.role`, set by the app's own signup/
    # invite flows — Supabase never puts it in the token on its own, and
    # nothing in this project's migrations adds a hook that would. Reading
    # `app_metadata.role` off the JWT, as this used to, would silently see
    # `None` for every user and fail every `require_roles` check.
    profile = db.get(Profile, user_id)

    return CurrentUser(
        id=user_id,
        email=payload.get("email"),
        role=profile.role if profile else None,
        estate_id=str(profile.estate_id) if profile and profile.estate_id else None,
    )


def require_roles(*allowed_roles: str):
    def dependency(user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
        if user.role not in allowed_roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You do not have access to this resource",
            )
        return user

    return dependency
