from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.routers import account, alerts, health, push, reports
from app.services.scheduler import register_jobs, scheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    register_jobs()
    scheduler.start()
    try:
        yield
    finally:
        scheduler.shutdown(wait=False)


app = FastAPI(
    title="Nafil Estates API",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    """
    A couple of low-cost, no-downside response headers — not a full CSP
    (this API serves JSON/PDFs to native apps and a browser SPA, not HTML
    it renders itself, so there's no markup surface for a CSP to protect).
    """
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    if request.url.scheme == "https":
        response.headers["Strict-Transport-Security"] = (
            "max-age=63072000; includeSubDomains"
        )
    return response


app.include_router(health.router)
app.include_router(reports.router)
app.include_router(alerts.router)
app.include_router(account.router)
app.include_router(push.router)
