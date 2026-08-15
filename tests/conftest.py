import os
from unittest.mock import MagicMock

import pytest

# Settings is instantiated at import time (app/core/config.py), so required
# env vars must exist before anything imports app.main — tests never touch a
# real Supabase project, so these are just placeholders satisfying validation.
os.environ.setdefault("SUPABASE_URL", "https://test.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key")
os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost/test")

from fastapi.testclient import TestClient

from app.core.db import get_db
from app.main import app


@pytest.fixture
def mock_db():
    return MagicMock()


@pytest.fixture
def client(mock_db):
    # Deliberately not using TestClient as a context manager: that would run
    # app.main's lifespan (starts the APScheduler background thread), which
    # these tests have no need for and would just add flakiness risk.
    app.dependency_overrides[get_db] = lambda: mock_db
    yield TestClient(app)
    app.dependency_overrides.clear()
