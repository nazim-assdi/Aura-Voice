from ipaddress import ip_address

from fastapi import Request


def get_client_ip(request: Request) -> str:
    """Resolve the visitor IP behind Render's Cloudflare edge.

    Cloudflare overwrites CF-Connecting-IP with the address of the connected
    visitor before forwarding the request to Render. Do not use an arbitrary
    X-Forwarded-For value here: clients may supply that header themselves.
    """
    forwarded = request.headers.get("cf-connecting-ip", "").strip()
    if forwarded:
        try:
            return ip_address(forwarded).compressed
        except ValueError:
            pass

    peer = request.client.host if request.client else ""
    if peer:
        try:
            return ip_address(peer).compressed
        except ValueError:
            pass
    return "unknown"
