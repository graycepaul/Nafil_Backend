from fastapi import APIRouter, Depends, Header, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.db import get_db
from app.models.models import PushToken
from app.schemas.push import NotifyUserRequest, NotifyUserResponse
from app.services.push import send_push_notifications

router = APIRouter(prefix="/push", tags=["push"])


@router.post("/notify-user")
def notify_user(
    request: NotifyUserRequest,
    db: Session = Depends(get_db),
    x_internal_secret: str = Header(default=""),
) -> NotifyUserResponse:
    """
    Called by a Postgres trigger (private.push_notify_on_insert, see
    0028_generic_push_notifications.sql) whenever a row lands in
    `notifications` — the DB-level guarantee that populates that table can't
    itself reach Expo's push API, so it reaches out here instead. Not
    user-authenticated like every other endpoint (there's no signed-in user —
    it's Postgres calling), hence the shared-secret header rather than a
    Supabase JWT.
    """
    if (
        not settings.internal_push_secret
        or x_internal_secret != settings.internal_push_secret
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authorized"
        )

    tokens = list(
        db.scalars(
            select(PushToken.token).where(PushToken.profile_id == request.profile_id)
        )
    )

    tickets_sent, errors = send_push_notifications(
        tokens=tokens,
        title=request.title,
        body=request.body,
        data=request.data,
    )

    return NotifyUserResponse(
        recipients=len(tokens), tickets_sent=tickets_sent, errors=errors
    )
