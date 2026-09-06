from pydantic import BaseModel, Field

ALERT_CATEGORIES = ("missing_child", "security_breach", "epidemic", "other")

CATEGORY_LABELS: dict[str, str] = {
    "missing_child": "Missing Child",
    "security_breach": "Security Breach",
    "epidemic": "Epidemic",
    "other": "Emergency",
}


class BroadcastRequest(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=500)
    category: str | None = None
    # super_admin only - lets them target an estate other than their own home
    # one. Ignored for admin/security, who can only ever broadcast to their
    # own estate regardless of what's sent here.
    estate_id: str | None = None
    # The in-app announcement's own photo, if the admin attached one - passed
    # straight through into the push payload so the foreground emergency
    # modal can render the same image, not just title/body.
    photo_url: str | None = None


class BroadcastResponse(BaseModel):
    recipients: int
    tickets_sent: int
    errors: list[str]
