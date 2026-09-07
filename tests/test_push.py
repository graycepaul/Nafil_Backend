import uuid
from unittest.mock import patch

RESIDENT_1 = str(uuid.uuid4())
RESIDENT_2 = str(uuid.uuid4())

BATCH_BODY = {
    "items": [
        {
            "profile_id": RESIDENT_1,
            "title": "New announcement",
            "body": "Pool maintenance this weekend.",
            "data": {"announcement_id": "ann-1"},
        },
        {
            "profile_id": RESIDENT_2,
            "title": "New announcement",
            "body": "Pool maintenance this weekend.",
            "data": {"announcement_id": "ann-1"},
        },
    ]
}

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
        mock_send.return_value = (1, [], [])
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
    # interruption-level overrides - those are alerts.py's job only.
    assert "sound" not in mock_send.call_args.kwargs
    assert "channel_id" not in mock_send.call_args.kwargs
    assert "interruption_level" not in mock_send.call_args.kwargs


def test_notify_batch_requires_correct_secret(client):
    response = client.post(
        "/push/notify-batch", json=BATCH_BODY, headers={"X-Internal-Secret": "wrong"}
    )
    assert response.status_code == 401


def test_notify_batch_rejects_missing_secret(client):
    response = client.post("/push/notify-batch", json=BATCH_BODY)
    assert response.status_code == 401


def test_notify_batch_sends_one_call_for_every_recipient(client, mock_db):
    # One query returning tokens for both profiles in the batch - the whole
    # point of /notify-batch is that this is the only DB round trip and
    # send_push_messages is called exactly once, regardless of how many
    # items/recipients are in the batch.
    #
    # profile_id comes back as an actual uuid.UUID here, not a plain string -
    # that's what PushToken.profile_id (a UUID column) really returns via
    # SQLAlchemy. A prior version of this test used bare strings, which
    # masked a real production bug: notify_batch keyed its dict by the
    # request's string profile_ids but then looked it up with these UUID
    # objects, so this exact query result 404'd through to a KeyError on
    # every real request while this test kept passing.
    mock_db.execute.return_value = [
        (uuid.UUID(RESIDENT_1), "token-a"),
        (uuid.UUID(RESIDENT_2), "token-b"),
    ]

    with patch("app.routers.push.send_push_messages") as mock_send:
        mock_send.return_value = (2, [], [])
        response = client.post(
            "/push/notify-batch",
            json=BATCH_BODY,
            headers={"X-Internal-Secret": "test-internal-push-secret"},
        )

    assert response.status_code == 200
    assert response.json() == {"recipients": 2, "tickets_sent": 2, "errors": []}
    mock_send.assert_called_once()
    sent_messages = mock_send.call_args.args[0]
    assert {m["to"] for m in sent_messages} == {"token-a", "token-b"}
    assert all(m["title"] == "New announcement" for m in sent_messages)


def test_notify_batch_skips_recipients_with_no_tokens(client, mock_db):
    # resident-2 has no registered device - shouldn't error, just contribute
    # nothing to the outgoing message list.
    mock_db.execute.return_value = [(uuid.UUID(RESIDENT_1), "token-a")]

    with patch("app.routers.push.send_push_messages") as mock_send:
        mock_send.return_value = (1, [], [])
        response = client.post(
            "/push/notify-batch",
            json=BATCH_BODY,
            headers={"X-Internal-Secret": "test-internal-push-secret"},
        )

    assert response.status_code == 200
    assert response.json()["recipients"] == 1
    sent_messages = mock_send.call_args.args[0]
    assert len(sent_messages) == 1
    assert sent_messages[0]["to"] == "token-a"
