# Stands in for IBM Verify during rehearsal when no real tenant is wired up
# yet: mints an RS256 JWT carrying the exact claims Vault's OBO+RAR flow
# needs (sub = human, act.sub = agent, authorization_details = RAR scoped
# to one Vault path+capability), and writes the matching JWKS so Vault can
# verify it. Pair with configure_mock_idp.sh, which serves that JWKS and
# points Vault's oauth-resource-server config at it. Confirmed working
# end-to-end against this repo's Vault 2.2.0+ent on 2026-10-18 -- see
# docs/TALK-NOTES.md "Agent Registry + identity wiring".
#
# Requires: pyjwt, cryptography (pip install pyjwt cryptography).
import json, base64, time, uuid, sys
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
import jwt

KEY_PATH = "/tmp/mock_idp_key.pem"
JWKS_PATH = "/tmp/mock_idp_jwks.json"
KID = "mock-idp-key-1"

def b64url(n: int, length: int) -> str:
    return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()

def ensure_key():
    try:
        with open(KEY_PATH, "rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
        return key
    except FileNotFoundError:
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with open(KEY_PATH, "wb") as f:
            f.write(key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            ))
        return key

def write_jwks(key):
    pub = key.public_key().public_numbers()
    jwks = {"keys": [{
        "kty": "RSA", "use": "sig", "alg": "RS256", "kid": KID,
        "n": b64url(pub.n, 256), "e": b64url(pub.e, 3),
    }]}
    with open(JWKS_PATH, "w") as f:
        json.dump(jwks, f)

def mint(issuer, subject, actor_sub, rar_path, rar_capability, ttl=60):
    key = ensure_key()
    write_jwks(key)
    now = int(time.time())
    claims = {
        "iss": issuer,
        "sub": subject,
        "act": {"sub": actor_sub},
        "authorization_details": [{
            "type": "vault:path_access",
            "path": rar_path,
            "capabilities": [rar_capability],
        }],
        "iat": now,
        "exp": now + ttl,
        "jti": str(uuid.uuid4()),
    }
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    token = jwt.encode(claims, pem, algorithm="RS256", headers={"kid": KID})
    return token

if __name__ == "__main__":
    args = sys.argv[1:]
    ttl = 60
    if "--ttl" in args:
        i = args.index("--ttl")
        ttl = int(args.pop(i + 1))
        args.pop(i)
    issuer, subject, actor_sub, rar_path, rar_capability = args
    print(mint(issuer, subject, actor_sub, rar_path, rar_capability, ttl=ttl))
