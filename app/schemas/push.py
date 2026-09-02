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
