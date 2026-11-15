from datetime import datetime, timezone
import time

from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession


FREE_DAILY_GENERATIONS = 50
FREE_DAILY_CHARACTERS = 50000


def utc_period_key() -> str:
    return datetime.now(timezone.utc).date().isoformat()


async def enforce_rate_limit(
    session: AsyncSession,
    bucket_key: str,
    *,
    limit: int,
    window_seconds: int = 60,
) -> int:
    window = int(time.time()) // window_seconds
    result = await session.execute(
        text(
            """
            INSERT INTO rate_limit_buckets (bucket_key, window_start, hit_count)
            VALUES (:key, :window, 1)
            ON CONFLICT (bucket_key, window_start)
            DO UPDATE SET hit_count = rate_limit_buckets.hit_count + 1
            RETURNING hit_count
            """
        ),
        {"key": bucket_key[:180], "window": window},
    )
    count = result.scalar_one()
    retry_after = window_seconds - (int(time.time()) % window_seconds)
    if count > limit:
        # Persist the rejected hit too, so concurrent/repeated requests cannot
        # roll the bucket back to the threshold when the dependency closes.
        await session.commit()
        raise HTTPException(
            status_code=429,
            detail={
                "code": "rate_limit_exceeded",
                "message": "Too many requests. Please slow down and try again.",
                "retry_after_seconds": retry_after,
            },
            headers={"Retry-After": str(retry_after)},
        )
    await session.commit()
    return count


async def consume_generation_quota(
    session: AsyncSession,
    owner_id: str,
    character_count: int,
) -> dict[str, int]:
    if character_count < 1 or character_count > 5000:
        raise HTTPException(
            status_code=422,
            detail="Script must contain between 1 and 5,000 characters.",
        )
    period = utc_period_key()
    result = await session.execute(
        text(
            """
            INSERT INTO usage_buckets
                (owner_id, period_key, generation_count, character_count)
            VALUES (:owner, :period, 1, :characters)
            ON CONFLICT (owner_id, period_key)
            DO UPDATE SET
                generation_count = usage_buckets.generation_count + 1,
                character_count = usage_buckets.character_count + :characters
            WHERE usage_buckets.generation_count < :max_generations
              AND usage_buckets.character_count + :characters <= :max_characters
            RETURNING generation_count, character_count
            """
        ),
        {
            "owner": owner_id,
            "period": period,
            "characters": character_count,
            "max_generations": FREE_DAILY_GENERATIONS,
            "max_characters": FREE_DAILY_CHARACTERS,
        },
    )
    row = result.first()
    if row is None:
        await session.rollback()
        raise HTTPException(
            status_code=429,
            detail={
                "code": "daily_quota_reached",
                "message": "Your free daily limit is 50 generations or 50,000 characters. Try again tomorrow.",
                "daily_generation_limit": FREE_DAILY_GENERATIONS,
                "daily_character_limit": FREE_DAILY_CHARACTERS,
            },
        )
    await session.commit()
    return {"generations_today": row[0], "characters_today": row[1]}


async def refund_generation_quota(
    session: AsyncSession,
    owner_id: str,
    character_count: int,
) -> None:
    """Undo a reserved quota unit when the upstream voice provider fails."""
    await session.execute(
        text(
            """
            UPDATE usage_buckets
            SET generation_count = CASE
                    WHEN generation_count > 0 THEN generation_count - 1
                    ELSE 0
                END,
                character_count = CASE
                    WHEN character_count >= :characters
                    THEN character_count - :characters
                    ELSE 0
                END
            WHERE owner_id = :owner AND period_key = :period
            """
        ),
        {
            "owner": owner_id,
            "period": utc_period_key(),
            "characters": character_count,
        },
    )
    await session.commit()
