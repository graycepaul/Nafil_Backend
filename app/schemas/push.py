from pydantic import BaseModel, Field


class NotifyUserRequest(BaseModel):
    profile_id: str
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=500)
    data: dict = Field(default_factory=dict)


class NotifyUserResponse(BaseModel):
    recipients: int
    tickets_sent: int
    errors: list[str]


class NotifyBatchRequest(BaseModel):
    """One entry per `notifications` row from a single bulk insert (see
    private.push_notify_on_insert_batch in
    0041_batch_push_notifications.sql) - a 500-resident announcement is one
    request with 500 items, not 500 requests."""

    items: list[NotifyUserRequest] = Field(min_length=1, max_length=5000)


class NotifyBatchResponse(BaseModel):
    recipients: int
    tickets_sent: int
    errors: list[str]
