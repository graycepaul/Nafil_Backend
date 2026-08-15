from unittest.mock import patch

from app.core.security import CurrentUser, get_current_user
from app.main import app

BROADCAST_BODY = {
    "title": "Test Alert",
    "body": "Please evacuate.",
    "category": "other",
}


def override_user(role: str, estate_id: str | None = "estate-1"):
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id="user-1", email="test@example.com", role=role, estate_id=estate_id
    )


def test_broadcast_requires_auth(client):
    response = client.post("/alerts/broadcast", json=BROADCAST_BODY)
    assert response.status_code == 403


def test_broadcast_rejects_disallowed_role(client):
    override_user(role="resident")
    response = client.post("/alerts/broadcast", json=BROADCAST_BODY)
    assert response.status_code == 403


def test_broadcast_requires_estate(client):
    override_user(role="security", estate_id=None)
    response = client.post("/alerts/broadcast", json=BROADCAST_BODY)
    assert response.status_code == 400


def test_broadcast_sends_to_estate_tokens(client, mock_db):
    override_user(role="security")
    mock_db.scalars.return_value = ["token-a", "token-b"]

    with patch("app.routers.alerts.send_push_notifications") as mock_send:
        mock_send.return_value = (2, [])
        response = client.post("/alerts/broadcast", json=BROADCAST_BODY)

    assert response.status_code == 200
    assert response.json() == {"recipients": 2, "tickets_sent": 2, "errors": []}
    mock_send.assert_called_once()
    assert mock_send.call_args.kwargs["tokens"] == ["token-a", "token-b"]
