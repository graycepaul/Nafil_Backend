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
    # fastapi's HTTPBearer raises 401 for a missing Authorization header
    # (403 in older fastapi versions was a long-standing quirk; 401 is the
    # HTTP-spec-correct code for "not authenticated at all").
    assert response.status_code == 401


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
        mock_send.return_value = (2, [], [])
        response = client.post("/alerts/broadcast", json=BROADCAST_BODY)

    assert response.status_code == 200
    assert response.json() == {"recipients": 2, "tickets_sent": 2, "errors": []}
    mock_send.assert_called_once()
    assert mock_send.call_args.kwargs["tokens"] == ["token-a", "token-b"]
    # Regression guard: Expo's API validates this against APNs' own enum,
    # which is hyphenated ("time-sensitive"). The camelCase("timeSensitive")
    # this code shipped with made Expo reject the *entire* batch with a 400
    # - nobody in it got pushed, silently, since a 400 here still gets
    # caught and turned into a normal `errors` entry rather than raising.
    assert mock_send.call_args.kwargs["interruption_level"] == "time-sensitive"


def test_broadcast_excludes_the_posters_device(client, mock_db):
    """
    Regression guard: the token query used to select every device in the
    estate with no exclusion at all, so whoever posted the alert got it
    pushed to their own phone alongside everyone else's - confirmed live
    when a super_admin posted an emergency alert and immediately got the
    push themselves. Per-device (poster_token), not per-account: the
    poster's *other* devices should still get pushed.
    """
    override_user(role="super_admin")
    captured_query = {}

    def scalars(query):
        captured_query["value"] = query
        return ["token-b"]

    mock_db.scalars.side_effect = scalars

    with patch("app.routers.alerts.send_push_notifications") as mock_send:
        mock_send.return_value = (1, [], [])
        client.post(
            "/alerts/broadcast", json={**BROADCAST_BODY, "poster_token": "token-a"}
        )

    mock_send.assert_called_once()
    assert "push_tokens.token != :token_1" in str(captured_query["value"])


def test_broadcast_without_poster_token_excludes_nothing(client, mock_db):
    """An older client that doesn't send poster_token yet shouldn't have the
    whole recipient list silently wiped out by a bad null comparison."""
    override_user(role="security")
    mock_db.scalars.return_value = ["token-a", "token-b"]

    with patch("app.routers.alerts.send_push_notifications") as mock_send:
        mock_send.return_value = (2, [], [])
        response = client.post("/alerts/broadcast", json=BROADCAST_BODY)

    assert response.json()["recipients"] == 2
