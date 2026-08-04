from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel


class VisitorLogEntry(BaseModel):
    visitor_name: str
    vehicle_plate: str | None
    method: str
    checked_in_at: datetime
    checked_out_at: datetime | None

    model_config = {"from_attributes": True}


class VisitorReportRequest(BaseModel):
    estate_id: UUID
    start_date: date
    end_date: date


class EstateStats(BaseModel):
    estate_id: UUID
    estate_name: str
    total_residents: int
    pending_approvals: int
    visitors_today: int
    open_issues: int
