def test_health_ok(client, mock_db):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    mock_db.execute.assert_called_once()
