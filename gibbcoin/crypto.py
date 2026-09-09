"""Kryptografie fuer GibbCoin - reine Standardbibliothek, keine Abhaengigkeiten.

Enthaelt eine kompakte Ed25519-Implementierung (RFC 8032) sowie Base58Check
fuer die Adressen. Die Ed25519-Variante ist die Referenzimplementierung: sie
ist korrekt, aber nicht seitenkanalfest. Fuer echtes Geld bitte PyNaCl nutzen.
"""

from __future__ import annotations

import hashlib
import os

# --- Hashes --------------------------------------------------------------


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def double_sha256(data: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def hash_to_int(digest: bytes) -> int:
    return int.from_bytes(digest, "big")


# --- Ed25519 (RFC 8032, Referenzimplementierung) --------------------------

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _sha512(data: bytes) -> bytes:
    return hashlib.sha512(data).digest()


def _x_recover(y: int) -> int:
    xx = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P)
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = (x * _I) % _P
    if x % 2 != 0:
        x = _P - x
    return x


_BY = 4 * pow(5, _P - 2, _P) % _P
_BX = _x_recover(_BY)
_B = (_BX % _P, _BY % _P, 1, _BX * _BY % _P)


def _point_add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = 2 * t1 * t2 * _D % _P
    dd = 2 * z1 * z2 % _P
    e, f, g, h = b - a, dd - c, dd + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _scalar_mult(p, e: int):
    q = (0, 1, 1, 0)
    while e > 0:
        if e & 1:
            q = _point_add(q, p)
        p = _point_add(p, p)
        e >>= 1
    return q


def _encode_point(p) -> bytes:
    x, y, z, _ = p
    zi = pow(z, _P - 2, _P)
    x = x * zi % _P
    y = y * zi % _P
    return ((y & ~(1 << 255)) | ((x & 1) << 255)).to_bytes(32, "little")


def _decode_point(s: bytes):
    n = int.from_bytes(s, "little")
    y = n & ((1 << 255) - 1)
    x = _x_recover(y)
    if x & 1 != (n >> 255) & 1:
        x = _P - x
    p = (x, y, 1, x * y % _P)
    if not _is_on_curve(p):
        raise ValueError("Punkt liegt nicht auf der Kurve")
    return p


def _is_on_curve(p) -> bool:
    x, y, z, t = p
    return (
        z % _P != 0
        and x * y % _P == z * t % _P
        and (y * y - x * x - z * z - _D * t * t) % _P == 0
    )


def _secret_scalar(seed: bytes) -> tuple[int, bytes]:
    h = _sha512(seed)
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def generate_seed() -> bytes:
    """32 zufaellige Bytes = privater Schluessel."""
    return os.urandom(32)


def public_key(seed: bytes) -> bytes:
    a, _ = _secret_scalar(seed)
    return _encode_point(_scalar_mult(_B, a))


def sign(seed: bytes, message: bytes) -> bytes:
    a, prefix = _secret_scalar(seed)
    pub = _encode_point(_scalar_mult(_B, a))
    r = int.from_bytes(_sha512(prefix + message), "little") % _L
    big_r = _encode_point(_scalar_mult(_B, r))
    k = int.from_bytes(_sha512(big_r + pub + message), "little") % _L
    s = (r + k * a) % _L
    return big_r + s.to_bytes(32, "little")


def verify(pub: bytes, message: bytes, signature: bytes) -> bool:
    if len(signature) != 64 or len(pub) != 32:
        return False
    try:
        big_r = _decode_point(signature[:32])
        point_a = _decode_point(pub)
    except (ValueError, ZeroDivisionError):
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    k = int.from_bytes(_sha512(signature[:32] + pub + message), "little") % _L
    lhs = _scalar_mult(_B, s)
    rhs = _point_add(big_r, _scalar_mult(point_a, k))
    return _encode_point(lhs) == _encode_point(rhs)


# --- Base58Check / Adressen ----------------------------------------------

_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
ADDRESS_VERSION = 0x26  # ergibt Adressen, die immer mit "G" beginnen


def b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    out = ""
    while n > 0:
        n, r = divmod(n, 58)
        out = _ALPHABET[r] + out
    for byte in data:
        if byte != 0:
            break
        out = _ALPHABET[0] + out
    return out or _ALPHABET[0]


def b58decode(text: str) -> bytes:
    n = 0
    for char in text:
        idx = _ALPHABET.find(char)
        if idx < 0:
            raise ValueError(f"ungueltiges Base58-Zeichen: {char!r}")
        n = n * 58 + idx
    body = n.to_bytes((n.bit_length() + 7) // 8, "big")
    pad = len(text) - len(text.lstrip(_ALPHABET[0]))
    return b"\x00" * pad + body


def public_key_to_address(pub: bytes) -> str:
    payload = bytes([ADDRESS_VERSION]) + sha256(pub)[:20]
    return b58encode(payload + double_sha256(payload)[:4])


def is_valid_address(address: str) -> bool:
    try:
        raw = b58decode(address)
    except ValueError:
        return False
    if len(raw) != 25 or raw[0] != ADDRESS_VERSION:
        return False
    return double_sha256(raw[:21])[:4] == raw[21:]


def address_matches_pubkey(address: str, pub: bytes) -> bool:
    return is_valid_address(address) and public_key_to_address(pub) == address
