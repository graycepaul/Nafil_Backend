from unittest.mock import patch

from app.core.security import CurrentUser, get_current_user
from app.main import app


def override_user(role: str = "resident"):
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id="user-1", email="test@example.com", role=role, estate_id="estate-1"
    )


def test_delete_account_requires_auth(client):
    response = client.delete("/account")
    # fastapi's HTTPBearer raises 401 for a missing Authorization header
    # (403 in older fastapi versions was a long-standing quirk; 401 is the
    # HTTP-spec-correct code for "not authenticated at all").
    assert response.status_code == 401


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


def test_delete_account_already_deleted_is_success(client):
    """A retry after an earlier request whose response never reached the
    client (e.g. dropped connection) hits an already-deleted user - Supabase
    returns 404, which must resolve as success rather than a confusing
    "failed, try again" error for an account that's already gone."""
    override_user()
    with patch("app.routers.account.httpx.delete") as mock_delete:
        mock_delete.return_value.status_code = 404
        response = client.delete("/account")

    assert response.status_code == 204


def test_delete_account_blocks_staff_roles(client):
    """Staff access (admin/security/finance) is institutional, not a personal
    account someone unilaterally walks away with - only a super_admin ends
    it. This is the actual enforcement boundary; the app's UI hiding the
    button for these roles is not one on its own."""
    for role in ("admin", "security", "finance"):
        override_user(role)
        with patch("app.routers.account.httpx.delete") as mock_delete:
            response = client.delete("/account")

        assert response.status_code == 403, f"expected 403 for role={role}"
        mock_delete.assert_not_called()


def test_delete_account_allows_resident_and_super_admin(client):
    for role in ("resident", "super_admin"):
        override_user(role)
        with patch("app.routers.account.httpx.delete") as mock_delete:
            mock_delete.return_value.status_code = 200
            response = client.delete("/account")

        assert response.status_code == 204, f"expected 204 for role={role}"
        mock_delete.assert_called_once()
