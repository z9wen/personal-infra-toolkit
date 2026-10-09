"""Unit tests for the URL shortener handler.

A small in-memory fake replaces the DynamoDB table, so the tests run without
AWS credentials, network access or boto3.
"""

from __future__ import annotations

import base64
import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import handler  # noqa: E402


class ConditionalCheckFailed(Exception):
    """Mimics botocore's ClientError shape for a failed condition."""

    response = {"Error": {"Code": "ConditionalCheckFailedException"}}


class FakeTable:
    def __init__(self, collisions: int = 0):
        self.items: dict[str, dict] = {}
        self.collisions = collisions

    def put_item(self, Item, ConditionExpression=None):
        if self.collisions > 0:
            self.collisions -= 1
            raise ConditionalCheckFailed()
        if ConditionExpression and Item["code"] in self.items:
            raise ConditionalCheckFailed()
        self.items[Item["code"]] = Item

    def get_item(self, Key):
        item = self.items.get(Key["code"])
        return {"Item": item} if item else {}


@pytest.fixture
def table(monkeypatch):
    fake = FakeTable()
    monkeypatch.setattr(handler, "_table", fake)
    return fake


def event(route_key, body=None, path_parameters=None, base64_body=False):
    raw = json.dumps(body) if body is not None else None
    if raw is not None and base64_body:
        raw = base64.b64encode(raw.encode()).decode()
    return {
        "routeKey": route_key,
        "body": raw,
        "isBase64Encoded": base64_body,
        "pathParameters": path_parameters,
        "requestContext": {"domainName": "abc123.execute-api.ap-east-1.amazonaws.com"},
    }


def body_of(result):
    return json.loads(result["body"])


def test_health_reports_lambda_version(monkeypatch):
    monkeypatch.setenv("AWS_LAMBDA_FUNCTION_VERSION", "7")
    result = handler.lambda_handler(event("GET /health"), None)
    assert result["statusCode"] == 200
    assert body_of(result) == {"status": "ok", "version": "7"}


def test_create_then_resolve_link(table):
    created = handler.lambda_handler(event("POST /links", {"url": "https://example.com/a?b=c"}), None)
    assert created["statusCode"] == 201
    code = body_of(created)["code"]
    assert body_of(created)["short_url"].endswith(f"/{code}")

    resolved = handler.lambda_handler(event("GET /{code}", path_parameters={"code": code}), None)
    assert resolved["statusCode"] == 301
    assert resolved["headers"]["Location"] == "https://example.com/a?b=c"


def test_create_accepts_base64_body(table):
    result = handler.lambda_handler(event("POST /links", {"url": "https://example.com"}, base64_body=True), None)
    assert result["statusCode"] == 201


@pytest.mark.parametrize(
    "payload",
    [
        {"url": "javascript:alert(1)"},
        {"url": "ftp://example.com/file"},
        {"url": "not a url"},
        {"url": "https://example.com/" + "a" * 3000},
        {"url": 42},
        {},
        {"url": "https://example.com", "ttl_days": 0},
        {"url": "https://example.com", "ttl_days": 366},
        {"url": "https://example.com", "ttl_days": True},
        {"url": "https://example.com", "ttl_days": "30"},
    ],
)
def test_create_rejects_invalid_input(table, payload):
    result = handler.lambda_handler(event("POST /links", payload), None)
    assert result["statusCode"] == 400
    assert table.items == {}


def test_create_rejects_non_object_json(table):
    bad = event("POST /links")
    bad["body"] = "[1, 2, 3]"
    assert handler.lambda_handler(bad, None)["statusCode"] == 400
    bad["body"] = "{not json"
    assert handler.lambda_handler(bad, None)["statusCode"] == 400


def test_create_retries_on_code_collision(table):
    table.collisions = 2
    result = handler.lambda_handler(event("POST /links", {"url": "https://example.com"}), None)
    assert result["statusCode"] == 201
    assert len(table.items) == 1


def test_create_gives_up_after_repeated_collisions(table):
    table.collisions = handler.MAX_CREATE_ATTEMPTS
    with pytest.raises(RuntimeError):
        handler.lambda_handler(event("POST /links", {"url": "https://example.com"}), None)


def test_unexpected_storage_errors_propagate(monkeypatch):
    class BrokenTable(FakeTable):
        def put_item(self, Item, ConditionExpression=None):
            raise ConnectionError("dynamodb unavailable")

    monkeypatch.setattr(handler, "_table", BrokenTable())
    # Must raise so the invocation counts towards the Lambda Errors metric
    # that triggers a CodeDeploy rollback.
    with pytest.raises(ConnectionError):
        handler.lambda_handler(event("POST /links", {"url": "https://example.com"}), None)


def test_expired_link_is_not_found_before_ttl_cleanup(table):
    table.items["Expired1"] = {"code": "Expired1", "url": "https://example.com", "expires_at": int(time.time()) - 1}
    result = handler.lambda_handler(event("GET /{code}", path_parameters={"code": "Expired1"}), None)
    assert result["statusCode"] == 404


@pytest.mark.parametrize("code", ["missing1", "../etc", "", "a" * 40])
def test_unknown_or_malformed_code_is_not_found(table, code):
    result = handler.lambda_handler(event("GET /{code}", path_parameters={"code": code}), None)
    assert result["statusCode"] == 404


def test_unknown_route_is_not_found():
    assert handler.lambda_handler(event("DELETE /links"), None)["statusCode"] == 404
