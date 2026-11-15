from collections.abc import AsyncGenerator

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.core.config import settings


class Base(DeclarativeBase):
    pass


_engine = None
_session_factory = None


def get_engine():
    global _engine, _session_factory
    url = settings.effective_database_url
    if not url:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "database_not_configured",
                "message": "Production database is not configured. Set AURA_DATABASE_URL before enabling accounts.",
            },
        )
    if _engine is None:
        _engine = create_async_engine(
            url,
            pool_pre_ping=True,
            pool_recycle=300,
        )
        _session_factory = async_sessionmaker(
            _engine,
            expire_on_commit=False,
            class_=AsyncSession,
        )
    return _engine


async def init_database() -> bool:
    if not settings.effective_database_url:
        return False
    from app import models  # noqa: F401

    engine = get_engine()
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    return True


async def get_session() -> AsyncGenerator[AsyncSession, None]:
    get_engine()
    assert _session_factory is not None
    async with _session_factory() as session:
        yield session
