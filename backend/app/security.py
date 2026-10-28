"""Tokens, keys and hashes. Secrets are never stored in the database, only their hashes."""

import base64
import hashlib
import hmac
import logging
import secrets
from datetime import UTC, datetime, timedelta
from functools import lru_cache

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from app.config import get_settings
from app.contracts.auth.access_token_claims import AccessTokenClaims

log = logging.getLogger(__name__)

# Activation keys avoid letters that read like digits (O/0, I/1).
_KEY_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
_passwords = PasswordHasher()


@lru_cache
def private_key() -> Ed25519PrivateKey:
    encoded = get_settings().jwt_private_key
    if encoded:
        return Ed25519PrivateKey.from_private_bytes(base64.b64decode(encoded))
    log.warning("JWT_PRIVATE_KEY is not set: tokens are signed with a temporary key and die with this process")
    return Ed25519PrivateKey.generate()


def public_key() -> Ed25519PublicKey:
    return private_key().public_key()


def public_key_pem() -> str:
    """What media-server verifies access tokens with."""
    return (
        public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    )


def generate_private_key() -> str:
    """A new JWT_PRIVATE_KEY value."""
    raw = Ed25519PrivateKey.generate().private_bytes(
        serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()
    )
    return base64.b64encode(raw).decode()


def issue_access_token(claims: dict[str, object]) -> tuple[str, int]:
    """Signs the claims (without iat/exp) for ACCESS_TOKEN_TTL seconds; returns the token and its lifetime."""
    ttl = get_settings().access_token_ttl
    now = datetime.now(UTC)
    full = AccessTokenClaims.model_validate(
        {**claims, "iat": int(now.timestamp()), "exp": int((now + timedelta(seconds=ttl)).timestamp())}
    )
    return jwt.encode(full.model_dump(mode="json", exclude_none=True), private_key(), algorithm="EdDSA"), ttl


def decode_access_token(token: str) -> AccessTokenClaims:
    """Raises jwt.InvalidTokenError (or pydantic.ValidationError) for anything but a valid, unexpired token."""
    return AccessTokenClaims.model_validate(jwt.decode(token, public_key(), algorithms=["EdDSA"]))


def keyed_hash(value: str) -> str:
    """HMAC of a short secret (activation key, pairing code, device id): useless without HASH_SECRET."""
    return hmac.new(get_settings().hash_secret.encode(), value.encode(), hashlib.sha256).hexdigest()


def token_hash(token: str) -> str:
    """Hash of a long random token (refresh token): plain SHA-256 is enough at 256 bits."""
    return hashlib.sha256(token.encode()).hexdigest()


def new_refresh_token() -> str:
    return "rt_" + secrets.token_urlsafe(32)


def new_activation_key() -> str:
    """80 random bits as XXXX-XXXX-XXXX-XXXX; it is typed on the PC once."""
    chars = "".join(secrets.choice(_KEY_ALPHABET) for _ in range(16))
    return "-".join(chars[i : i + 4] for i in range(0, 16, 4))


def normalize_activation_key(key: str) -> str:
    return "".join(c for c in key.upper() if c.isalnum())


def new_pairing_code() -> str:
    return f"{secrets.randbelow(10**6):06d}"


def hash_password(password: str) -> str:
    return _passwords.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _passwords.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False
