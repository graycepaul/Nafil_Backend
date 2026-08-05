"""Sends push notifications through Expo's push service.

No native FCM/APNs credentials needed on this service's end — EAS holds
those, and Expo's push API (https://exp.host/--/api/v2/push/send) is the one
stable endpoint that routes to whichever platform each token belongs to. It
takes up to 100 messages per request, so a large resident list is chunked.
"""

import logging

import httpx

from app.core.config import settings

logger = logging.getLogger(__name__)

_PUSH_URL = "https://exp.host/--/api/v2/push/send"
_CHUNK_SIZE = 100


def _chunk(items: list[str], size: int) -> list[list[str]]:
    return [items[i : i + size] for i in range(0, len(items), size)]


def send_push_notifications(
    tokens: list[str],
    title: str,
    body: str,
    data: dict | None = None,
) -> tuple[int, list[str]]:
    """
    Returns (tickets_sent, errors). A ticket being accepted doesn't guarantee
    delivery — Expo's receipt endpoint would confirm that after the fact —
    but it does confirm Expo's push service accepted the token and queued the
    message, which is enough to tell the sender "this went out" versus
    "this token/request was rejected outright".
    """
    if not tokens:
        return 0, []

    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    if settings.expo_access_token:
        headers["Authorization"] = f"Bearer {settings.expo_access_token}"

    tickets_sent = 0
    errors: list[str] = []

    with httpx.Client(timeout=10) as client:
        for batch in _chunk(tokens, _CHUNK_SIZE):
            messages = [
                {
                    "to": token,
                    "title": title,
                    "body": body,
                    "data": data or {},
                    "sound": "default",
                    "priority": "high",
                    "channelId": "emergency",
                }
                for token in batch
            ]
            try:
                resp = client.post(_PUSH_URL, headers=headers, json=messages)
                resp.raise_for_status()
                payload = resp.json()
            except (httpx.HTTPError, ValueError) as exc:
                errors.append(f"Batch request failed: {exc}")
                continue

            for ticket in payload.get("data", []):
                if ticket.get("status") == "ok":
                    tickets_sent += 1
                else:
                    errors.append(ticket.get("message", "Unknown push error"))

    if errors:
        logger.warning("Push send had %s error(s): %s", len(errors), errors[:5])

    return tickets_sent, errors
