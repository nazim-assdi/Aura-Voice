import httpx

from app.core.config import settings


async def complete_chat(*, system: str, user: str, max_tokens: int = 1200) -> str:
    if not settings.llm_api_key.strip() or not settings.llm_model.strip():
        raise RuntimeError("Translation and AI conversation require AURA_LLM_API_KEY and AURA_LLM_MODEL.")
    base = settings.llm_base_url.rstrip("/")
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(
                f"{base}/chat/completions",
                headers={
                    "Authorization": f"Bearer {settings.llm_api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": settings.llm_model,
                    "temperature": 0.2,
                    "max_tokens": max_tokens,
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
            )
    except httpx.TimeoutException as exc:
        raise RuntimeError("The language model request timed out.") from exc
    except httpx.RequestError as exc:
        raise RuntimeError("Could not connect to the language model provider.") from exc
    if not response.is_success:
        raise RuntimeError(f"Language model provider returned HTTP {response.status_code}.")
    try:
        data = response.json()
        return data["choices"][0]["message"]["content"].strip()
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise RuntimeError("The language model returned an invalid response.") from exc
