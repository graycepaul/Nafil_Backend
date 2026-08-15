from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import CurrentUser, require_roles
from app.models.models import Profile, PushToken
from app.schemas.alerts import CATEGORY_LABELS, BroadcastRequest, BroadcastResponse
from app.services.push import send_push_notifications

router = APIRouter(prefix="/alerts", tags=["alerts"])


@router.post("/broadcast")
def broadcast(
    request: BroadcastRequest,
    db: Session = Depends(get_db),
    user: CurrentUser = Depends(require_roles("security", "admin", "super_admin")),
) -> BroadcastResponse:
    """
    Push an emergency alert to every resident device registered in the
    caller's own estate. The in-app announcement row is written by the
    client directly (via Supabase, same as any other announcement) — this
    endpoint only does the side effect Supabase/RLS can't: reaching a
    resident's phone even if they never open the app.
    """
    if not user.estate_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Your account isn't assigned to an estate",
        )

    tokens = list(
        db.scalars(
            select(PushToken.token)
            .join(Profile, Profile.id == PushToken.profile_id)
            .where(Profile.estate_id == user.estate_id)
        )
    )

    title = CATEGORY_LABELS.get(request.category or "", request.title)
    tickets_sent, errors = send_push_notifications(
        tokens=tokens,
        title=f"🚨 {title}",
        body=request.body,
        data={"category": request.category, "kind": "emergency_alert"},
    )

    return BroadcastResponse(
        recipients=len(tokens), tickets_sent=tickets_sent, errors=errors
    )
