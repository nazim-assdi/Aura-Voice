from fastapi import APIRouter

from app.api.v1.endpoints.assets import router as assets_router
from app.api.v1.endpoints.auth import router as auth_router
from app.api.v1.endpoints.dubbing import router as dubbing_router
from app.api.v1.endpoints.projects import router as projects_router
from app.api.v1.endpoints.realtime import router as realtime_router
from app.api.v1.endpoints.speech import router as speech_router
from app.api.v1.endpoints.system import router as system_router
from app.api.v1.endpoints.voices import router as voices_router

api_router = APIRouter()
api_router.include_router(system_router, tags=["system"])
api_router.include_router(auth_router, tags=["authentication"])
api_router.include_router(projects_router, tags=["projects"])
api_router.include_router(assets_router, tags=["audio assets"])
api_router.include_router(voices_router, tags=["voices"])
api_router.include_router(speech_router, prefix="/speech", tags=["speech"])
api_router.include_router(dubbing_router, tags=["dubbing"])
api_router.include_router(realtime_router, tags=["realtime and conversation"])
