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


def test_devcontrol_rejects_unknown_scope(client):
    override_user(role="dev_admin")
    assert client.get("/devcontrol/overview?scope=everything").status_code == 422


FLAG_BODY = {
    "kind": "user",
    "id": "00000000-0000-4000-8000-000000000001",
    "test": True,
}


def test_flag_requires_dev_admin(client):
    override_user(role="super_admin")
    assert client.post("/devcontrol/flags", json=FLAG_BODY).status_code == 403


def test_flag_rejects_unknown_kind(client):
    override_user(role="dev_admin")
    body = {**FLAG_BODY, "kind": "wallet"}
    assert client.post("/devcontrol/flags", json=body).status_code == 422


def test_flag_unknown_target_is_404(client, mock_db):
    override_user(role="dev_admin")
    mock_db.execute.return_value.first.return_value = None
    assert client.post("/devcontrol/flags", json=FLAG_BODY).status_code == 404
    mock_db.commit.assert_not_called()


def test_flag_sets_and_commits(client, mock_db):
    override_user(role="dev_admin")
    mock_db.execute.return_value.first.return_value = (1,)
    mock_db.execute.return_value.mappings.return_value.all.return_value = [
        {"is_test": True, "source": "manual"}
    ]
    response = client.post("/devcontrol/flags", json=FLAG_BODY)
    assert response.status_code == 200
    assert response.json() == {"is_test": True, "source": "manual"}
    mock_db.commit.assert_called_once()
