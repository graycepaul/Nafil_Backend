from unittest.mock import patch

NOTIFY_BODY = {
    "profile_id": "resident-1",
    "title": "Your report was resolved",
    "body": "The maintenance team marked this fixed.",
    "data": {"issue_id": "issue-1"},
}


def test_notify_user_requires_correct_secret(client):
    response = client.post(
        "/push/notify-user", json=NOTIFY_BODY, headers={"X-Internal-Secret": "wrong"}
    )
    assert response.status_code == 401


def test_notify_user_rejects_missing_secret(client):
    response = client.post("/push/notify-user", json=NOTIFY_BODY)
    assert response.status_code == 401


def test_notify_user_sends_to_profiles_tokens(client, mock_db):
    mock_db.scalars.return_value = ["token-a"]

    with patch("app.routers.push.send_push_notifications") as mock_send:
        mock_send.return_value = (1, [])
        response = client.post(
            "/push/notify-user",
            json=NOTIFY_BODY,
            headers={"X-Internal-Secret": "test-internal-push-secret"},
        )

    assert response.status_code == 200
    assert response.json() == {"recipients": 1, "tickets_sent": 1, "errors": []}
    mock_send.assert_called_once()
    assert mock_send.call_args.kwargs["tokens"] == ["token-a"]
    assert mock_send.call_args.kwargs["title"] == NOTIFY_BODY["title"]
    # A routine notification must NOT ride on the emergency channel/sound/
    # interruption-level overrides — those are alerts.py's job only.
    assert "sound" not in mock_send.call_args.kwargs
    assert "channel_id" not in mock_send.call_args.kwargs
    assert "interruption_level" not in mock_send.call_args.kwargs
