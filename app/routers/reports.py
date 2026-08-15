from datetime import date, datetime, time, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.db import get_db
from app.core.security import CurrentUser, require_roles
from app.models.models import Estate, VisitorLog
from app.schemas.reports import VisitorLogEntry
from app.services.pdf import build_visitor_report

router = APIRouter(prefix="/reports", tags=["reports"])


@router.get("/visitors.pdf")
def visitor_report(
    estate_id: UUID,
    start_date: date,
    end_date: date,
    db: Session = Depends(get_db),
    user: CurrentUser = Depends(require_roles("admin", "super_admin")),
) -> Response:
    """Visitor log for an estate over a date range, as a PDF."""
    if start_date > end_date:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="start_date must be on or before end_date",
        )

    estate = db.get(Estate, estate_id)
    if estate is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Estate not found"
        )

    start_dt = datetime.combine(start_date, time.min, tzinfo=timezone.utc)
    end_dt = datetime.combine(end_date, time.max, tzinfo=timezone.utc)

    logs = db.scalars(
        select(VisitorLog)
        .where(
            VisitorLog.estate_id == estate_id,
            VisitorLog.checked_in_at >= start_dt,
            VisitorLog.checked_in_at <= end_dt,
        )
        .order_by(VisitorLog.checked_in_at.desc())
    ).all()

    pdf = build_visitor_report(
        estate_name=estate.name,
        start_date=start_date,
        end_date=end_date,
        entries=[VisitorLogEntry.model_validate(log) for log in logs],
    )

    filename = f"visitors-{estate_id}-{start_date}-{end_date}.pdf"
    return Response(
        content=pdf,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
