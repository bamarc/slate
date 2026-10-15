"""Authentication endpoints — `/v1/me` and `/v1/mock-token`."""

from __future__ import annotations

import datetime

import jwt
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from app.core.auth import AuthenticatedUser, get_current_user
from app.core.auth.dependencies import ALGORITHM, MVP_MOCK_SECRET, is_local
from app.models._generated import MockTokenRequest, MockTokenResponse

router = APIRouter(prefix="/auth", tags=["Auth"])


class UserInfo(BaseModel):
    model_config = ConfigDict(frozen=True)

    subject: str = Field(..., description="Stable user id (token `sub`).")
    email: str | None = None
    name: str | None = None
    roles: list[str] = Field(default_factory=list)
    issuer: str


@router.get("/me", response_model=UserInfo, summary="Current authenticated user")
async def me(user: AuthenticatedUser = Depends(get_current_user)) -> UserInfo:
    return UserInfo(
        subject=user.subject,
        email=user.email,
        name=user.name,
        roles=sorted(user.roles),
        issuer=user.issuer,
    )


@router.post(
    "/mock-token",
    response_model=MockTokenResponse,
    summary="Issue a signed mock JWT for local development",
)
async def issue_mock_token(payload: MockTokenRequest) -> MockTokenResponse:
    if not is_local():
        raise HTTPException(
            status_code=404,
            detail="Mock token endpoint not available in this environment",
        )

    # Generate mock JWT
    now = datetime.datetime.now(datetime.UTC)
    expires = now + datetime.timedelta(hours=24)

    claims = {
        "sub": payload.kid,
        "kid": payload.kid,
        "name": payload.name or "Mock User",
        "email": payload.email or f"{payload.kid.lower()}@example.com",
        "roles": payload.roles or ["user"],
        "role": payload.roles[0] if payload.roles else "user",
        "iss": "mock-jwt",
        "aud": "mock-audience",
        "exp": int(expires.timestamp()),
        "iat": int(now.timestamp()),
    }

    token = jwt.encode(claims, MVP_MOCK_SECRET, algorithm=ALGORITHM)
    return MockTokenResponse(access_token=token, token_type="Bearer")
