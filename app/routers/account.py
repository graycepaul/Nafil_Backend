import httpx
from fastapi import APIRouter, Depends, HTTPException, status

from app.core.config import settings
from app.core.security import CurrentUser, get_current_user

router = APIRouter(prefix="/account", tags=["account"])


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(user: CurrentUser = Depends(get_current_user)) -> None:
    """
    Permanently deletes the caller's own account. Deleting an auth user is an
    admin-only operation Supabase's anon/client key can't perform, so this
    goes through the Admin API with the service role key instead. Every
    dependent row (profile, visitor passes, issues, household members,
    notifications, ...) cascades away via the same ON DELETE CASCADE chain
    already relied on for manual account cleanup — see supabase/seed.sql.
    """
    resp = httpx.delete(
        f"{settings.supabase_url}/auth/v1/admin/users/{user.id}",
        headers={
            "apikey": settings.supabase_service_role_key,
            "Authorization": f"Bearer {settings.supabase_service_role_key}",
        },
        timeout=10,
    )
    if resp.status_code not in (200, 204):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Failed to delete account. Please try again or contact support.",
        )
