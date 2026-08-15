from unittest.mock import patch

from app.core.security import CurrentUser, get_current_user
from app.main import app


def override_user():
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id="user-1", email="test@example.com", role="resident", estate_id="estate-1"
    )


def test_delete_account_requires_auth(client):
    response = client.delete("/account")
    assert response.status_code == 403


def test_delete_account_success(client):
    override_user()
    with patch("app.routers.account.httpx.delete") as mock_delete:
        mock_delete.return_value.status_code = 200
        response = client.delete("/account")

    assert response.status_code == 204
    mock_delete.assert_called_once()
    assert "user-1" in mock_delete.call_args.args[0]


def test_delete_account_upstream_failure(client):
    override_user()
    with patch("app.routers.account.httpx.delete") as mock_delete:
        mock_delete.return_value.status_code = 500
        response = client.delete("/account")

    assert response.status_code == 502
