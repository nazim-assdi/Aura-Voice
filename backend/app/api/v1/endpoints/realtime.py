import httpx
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.api.deps import CurrentUser, SessionDep
from app.core.config import settings
from app.core.limits import enforce_rate_limit
from app.services.llm import complete_chat

router = APIRouter(prefix="/realtime")


@router.post("/token")
async def create_realtime_access_token(
    request: Request,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, object]:
    await enforce_rate_limit(session, f"realtime-token:{user.id}", limit=10, window_seconds=60)
    host = request.client.host if request.client else "unknown"
    await enforce_rate_limit(session, f"realtime-token-ip:{host[:64]}", limit=30, window_seconds=60)
    if not settings.cartesia_api_key.strip():
        raise HTTPException(status_code=503, detail={"code": "cartesia_not_configured", "message": "Configure the Cartesia API key on the backend."})
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                "https://api.cartesia.ai/access-token",
                headers={
                    "Authorization": f"Bearer {settings.cartesia_api_key}",
                    "Cartesia-Version": settings.cartesia_version,
                    "Content-Type": "application/json",
                },
                json={"grants": {"tts": True, "stt": True, "agent": False}, "expires_in": 60},
            )
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail="Could not request a Cartesia realtime token.") from exc
    if not response.is_success:
        raise HTTPException(status_code=502, detail=f"Cartesia token service returned HTTP {response.status_code}.")
    token = response.json().get("token")
    if not token:
        raise HTTPException(status_code=502, detail="Cartesia did not return a realtime token.")
    response_data = {
        "token": token,
        "expires_in": 60,
        "cartesia_version": settings.cartesia_version,
        "tts_websocket": "wss://api.cartesia.ai/tts/websocket",
        "stt_websocket": "wss://api.cartesia.ai/stt/turns/websocket",
        "model_id": settings.cartesia_model_id,
        "stt_model_id": settings.cartesia_realtime_stt_model_id,
        "note": "Cartesia Ink-2 realtime STT currently supports English, Spanish, French, Hindi and Japanese. File transcription uses Ink-Whisper for broader language coverage.",
    }
    return response_data


class ConversationRequest(BaseModel):
    transcript: str = Field(min_length=1, max_length=6000)
    history: list[dict[str, str]] = Field(default_factory=list, max_length=12)


@router.post("/respond")
async def conversation_response(
    payload: ConversationRequest,
    request: Request,
    user: CurrentUser,
    session: SessionDep,
) -> dict[str, str]:
    await enforce_rate_limit(session, f"conversation:{user.id}", limit=30)
    host = request.client.host if request.client else "unknown"
    await enforce_rate_limit(session, f"conversation-ip:{host[:64]}", limit=90)
    history_text = "\n".join(
        f"{item.get('role', 'user')}: {item.get('content', '')[:1000]}"
        for item in payload.history[-10:]
        if item.get("role") in {"user", "assistant"}
    )
    prompt = (
        "You are Aura Voice, a concise, helpful voice conversation assistant. "
        "Reply naturally in the same language as the latest user message. "
        "Keep spoken replies brief, clear and suitable for text-to-speech."
    )
    try:
        answer = await complete_chat(
            system=prompt,
            user=f"Conversation so far:\n{history_text}\n\nLatest user turn:\n{payload.transcript}",
            max_tokens=500,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail={"code": "conversation_llm_not_configured", "message": str(exc)}) from exc
    return {"reply": answer}
