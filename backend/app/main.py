from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware

from app.api.v1.router import api_router
from app.core.config import settings
from app.db import init_database
from app.engines.registry import get_speech_provider


@asynccontextmanager
async def lifespan(app: FastAPI):
    database_ready = False
    if settings.effective_database_url:
        database_ready = await init_database()
    app.state.database_ready = database_ready
    yield


app = FastAPI(
    title=settings.app_name,
    version=settings.app_version,
    description="Aura Voice AI — authenticated voice production API with Cartesia TTS/STT, projects and realtime tokens.",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.parsed_cors_origins,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "X-Client-Type"],
)
app.add_middleware(GZipMiddleware, minimum_size=1200)


@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Permissions-Policy"] = "camera=(), geolocation=(), payment=()"
    response.headers["Cache-Control"] = response.headers.get("Cache-Control", "no-store")
    if settings.environment.lower() in {"production", "prod"}:
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response


app.include_router(api_router, prefix="/api/v1")


@app.get("/health", tags=["system"])
async def health() -> dict[str, object]:
    provider = get_speech_provider()
    database_ready = bool(getattr(app.state, "database_ready", False))
    return {
        "ok": True,
        "service": "aura-voice-api",
        "version": settings.app_version,
        "speech_provider": provider.name,
        "speech_ready": provider.is_ready,
        "database_ready": database_ready,
        "auth_ready": bool(database_ready and settings.auth_ready),
        "translation_ready": bool(settings.llm_api_key and settings.llm_model),
        "realtime_ready": bool(database_ready and settings.auth_ready and settings.cartesia_api_key),
    }
