"""URL shortener Lambda behind an API Gateway HTTP API (payload format 2.0).

Routes:
    GET  /health   liveness check that also reports the running Lambda version
    POST /links    create a short link: {"url": "https://...", "ttl_days": 30}
    GET  /{code}   301 redirect to the stored URL

Unexpected exceptions are deliberately *not* converted into HTTP 500
responses. Letting them propagate marks the invocation as failed, which feeds
the Lambda ``Errors`` metric that CodeDeploy watches to roll back a bad canary.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import secrets
import string
import time
from typing import Any
from urllib.parse import urlparse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALPHABET = string.ascii_letters + string.digits
CODE_LENGTH = int(os.environ.get("CODE_LENGTH", "7"))
CODE_PATTERN = re.compile(r"^[A-Za-z0-9]{4,16}$")
MAX_URL_LENGTH = 2048
DEFAULT_TTL_DAYS = 30
MAX_TTL_DAYS = 365
MAX_CREATE_ATTEMPTS = 5

_table = None


def get_table():
    """Create the DynamoDB table client once per execution environment.

    boto3 is imported lazily so unit tests can inject a fake table without
    needing AWS libraries or credentials.
    """
    global _table
    if _table is None:
        import boto3

        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def response(status: int, body: Any = None, headers: dict | None = None) -> dict:
    result: dict[str, Any] = {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **(headers or {})},
    }
    if body is not None:
        result["body"] = json.dumps(body)
    return result


def parse_json_body(event: dict) -> dict | None:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    return body if isinstance(body, dict) else None


def is_valid_target(url: Any) -> bool:
    if not isinstance(url, str) or len(url) > MAX_URL_LENGTH:
        return False
    parsed = urlparse(url)
    return parsed.scheme in ("http", "https") and bool(parsed.netloc)


def is_conditional_check_failure(exc: Exception) -> bool:
    error = getattr(exc, "response", {}).get("Error", {})
    return error.get("Code") == "ConditionalCheckFailedException"


def new_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(CODE_LENGTH))


def health(event: dict) -> dict:
    return response(
        200,
        {"status": "ok", "version": os.environ.get("AWS_LAMBDA_FUNCTION_VERSION", "local")},
    )


def create_link(event: dict) -> dict:
    body = parse_json_body(event)
    if body is None:
        return response(400, {"error": "request body must be a JSON object"})

    url = body.get("url")
    if not is_valid_target(url):
        return response(400, {"error": "url must be an absolute http(s) URL"})

    ttl_days = body.get("ttl_days", DEFAULT_TTL_DAYS)
    if not isinstance(ttl_days, int) or isinstance(ttl_days, bool) or not 1 <= ttl_days <= MAX_TTL_DAYS:
        return response(400, {"error": f"ttl_days must be an integer between 1 and {MAX_TTL_DAYS}"})

    now = int(time.time())
    table = get_table()
    for _ in range(MAX_CREATE_ATTEMPTS):
        code = new_code()
        try:
            # The condition makes a code collision fail instead of silently
            # overwriting someone else's link.
            table.put_item(
                Item={
                    "code": code,
                    "url": url,
                    "created_at": now,
                    "expires_at": now + ttl_days * 86400,
                },
                ConditionExpression="attribute_not_exists(code)",
            )
        except Exception as exc:
            if is_conditional_check_failure(exc):
                logger.warning("short code collision, retrying", extra={"code": code})
                continue
            raise
        domain = event.get("requestContext", {}).get("domainName", "")
        logger.info("link created", extra={"code": code, "ttl_days": ttl_days})
        return response(201, {"code": code, "short_url": f"https://{domain}/{code}"})

    raise RuntimeError(f"could not allocate a unique code after {MAX_CREATE_ATTEMPTS} attempts")


def resolve_link(event: dict) -> dict:
    code = (event.get("pathParameters") or {}).get("code", "")
    if not CODE_PATTERN.match(code):
        return response(404, {"error": "not found"})

    item = get_table().get_item(Key={"code": code}).get("Item")
    # DynamoDB TTL deletes expired items lazily (often hours later), so the
    # expiry must also be enforced on read.
    if item is None or int(item["expires_at"]) <= int(time.time()):
        return response(404, {"error": "not found"})

    return response(301, headers={"Location": item["url"], "Cache-Control": "no-store"})


ROUTES = {
    "GET /health": health,
    "POST /links": create_link,
    "GET /{code}": resolve_link,
}


def lambda_handler(event: dict, context: Any) -> dict:
    route = ROUTES.get(event.get("routeKey", ""))
    if route is None:
        return response(404, {"error": "not found"})
    return route(event)
