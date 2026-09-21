import jwt

from routers.auth import _verify_parent_jwt_locally


def test_garbage_token_falls_back_instead_of_crashing():
    assert _verify_parent_jwt_locally("not-a-real-jwt") is None


def test_wrong_signature_falls_back_instead_of_accepting():
    # Self-signed with a kid this project's real JWKS will never contain —
    # must come back None (fall back to the live check), never a user id.
    # This is the safety property that matters: local verification only
    # ever *skips* the slow path, it never gets to unilaterally accept a
    # token the live check would have rejected.
    token = jwt.encode(
        {"sub": "attacker-controlled-id", "aud": "authenticated"},
        "not-the-real-key",
        algorithm="HS256",
        headers={"kid": "not-a-real-kid"},
    )
    assert _verify_parent_jwt_locally(token) is None
