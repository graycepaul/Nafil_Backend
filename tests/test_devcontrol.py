from app.core.security import CurrentUser, get_current_user
from app.main import app


def override_user(role: str):
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id="user-1", email="test@example.com", role=role, estate_id=None
    )


def test_devcontrol_requires_auth(client):
    assert client.get("/devcontrol/overview").status_code == 401


def test_devcontrol_rejects_estate_roles(client):
    # super_admin is the estate owner role and must not see cross-estate data.
    for role in ("admin", "super_admin", "finance"):
        override_user(role=role)
        for path in (
            "/devcontrol/overview",
            "/devcontrol/estates",
            "/devcontrol/users",
        ):
            assert client.get(path).status_code == 403


def test_devcontrol_rejects_resident(client):
    override_user(role="resident")
    assert client.get("/devcontrol/users").status_code == 403
