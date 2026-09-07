import hmac

from fastapi import APIRouter, Depends, Header, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.db import get_db
from app.models.models import PushToken
from app.schemas.push import (
    NotifyBatchRequest,
    NotifyBatchResponse,
    NotifyUserRequest,
    NotifyUserResponse,
)
from app.services.push import (
    _build_messages,
    send_push_messages,
    send_push_notifications,
)

router = APIRouter(prefix="/push", tags=["push"])


def _check_internal_secret(x_internal_secret: str) -> None:
    # hmac.compare_digest rather than `!=` - a plain string comparison
    # short-circuits on the first mismatched byte, which leaks (via
    # response timing) how many leading characters of a guess are
    # correct. Not user-authenticated like every other endpoint (there's
    # no signed-in user - it's Postgres calling), hence a shared secret
    # rather than a Supabase JWT in the first place.
    if not settings.internal_push_secret or not hmac.compare_digest(
        x_internal_secret, settings.internal_push_secret
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authorized"
        )


@router.post("/notify-user")
def notify_user(
    request: NotifyUserRequest,
    db: Session = Depends(get_db),
    x_internal_secret: str = Header(default=""),
) -> NotifyUserResponse:
    """
    Single-recipient path, called by a Postgres trigger
    (private.push_notify_on_insert, see 0028_generic_push_notifications.sql)
    - kept for any one-off caller, but /notify-batch below is what the
    generic notifications trigger actually posts to now (0041), so a bulk
    event like an estate-wide announcement is one HTTP round trip carrying
    every recipient rather than one round trip per recipient.
    """
    _check_internal_secret(x_internal_secret)

    tokens = list(
        db.scalars(
            select(PushToken.token).where(PushToken.profile_id == request.profile_id)
        )
    )

    tickets_sent, errors, dead_tokens = send_push_notifications(
        tokens=tokens,
        title=request.title,
        body=request.body,
        data=request.data,
    )

    if dead_tokens:
        db.execute(delete(PushToken).where(PushToken.token.in_(dead_tokens)))
        db.commit()

    return NotifyUserResponse(
        recipients=len(tokens), tickets_sent=tickets_sent, errors=errors
    )


@router.post("/notify-batch")
def notify_batch(
    request: NotifyBatchRequest,
    db: Session = Depends(get_db),
    x_internal_secret: str = Header(default=""),
) -> NotifyBatchResponse:
    """
    Called once per triggering SQL statement by
    private.push_notify_on_insert_batch (0041_batch_push_notifications.sql)
    - a single `insert into notifications select ... from profiles` for a
    500-resident announcement fires this ONCE with all 500 items, rather
    than 500 separate calls to /notify-user. One query fetches every
    involved profile's tokens up front, and every resulting Expo message
    (however many different notifications/recipients it spans) is handed to
    send_push_messages together, so Expo's own 100-per-request batching
    still applies across the whole event instead of resetting per profile.
    """
    _check_internal_secret(x_internal_secret)

    profile_ids = {item.profile_id for item in request.items}
    tokens_by_profile: dict[str, list[str]] = {pid: [] for pid in profile_ids}
    for profile_id, token in db.execute(
        select(PushToken.profile_id, PushToken.token).where(
            PushToken.profile_id.in_(profile_ids)
        )
    ):
        tokens_by_profile[profile_id].append(token)

    messages: list[dict] = []
    for item in request.items:
        messages.extend(
            _build_messages(
                tokens_by_profile.get(item.profile_id, []),
                item.title,
                item.body,
                item.data,
                sound="default",
                priority="default",
                channel_id="default",
                interruption_level=None,
            )
        )

    tickets_sent, errors, dead_tokens = send_push_messages(messages)

    if dead_tokens:
        db.execute(delete(PushToken).where(PushToken.token.in_(dead_tokens)))
        db.commit()

    return NotifyBatchResponse(
        recipients=len(messages), tickets_sent=tickets_sent, errors=errors
    )
