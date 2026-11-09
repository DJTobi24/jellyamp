"""Sonic Sage through the real Anthropic SDK, with the network replaced by a
canned HTTP response: checks the request the SDK actually puts on the wire
(structured-output schema, fallback opt-in, no leaked extras) and that its
answer parses back into `SageCriteria`. No API key or network needed."""

import json

import pytest

from jellyamp_server.sonic import sage

anthropic = pytest.importorskip("anthropic")
# The SDK's own HTTP library (a fork of httpx with the same API).
httpx = pytest.importorskip("httpx2")

ANSWER = {
    "title": "Smoky Late Night",
    "description": "Jazz for after midnight.",
    "genres": ["Jazz"],
    "year_from": 1955,
    "year_to": None,
    "seed_artists": ["Blue Hour Trio"],
    "seed_tracks": [],
    "energy": "low",
}


def message(stop_reason: str = "end_turn", text: str | None = None) -> dict:
    return {
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "model": "claude-opus-5-5",
        "content": [{"type": "text", "text": json.dumps(ANSWER) if text is None else text}],
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 10, "output_tokens": 10},
    }


def llm_with(handler, model: str = "claude-opus-5-5") -> sage.AnthropicSageLLM:
    llm = sage.AnthropicSageLLM("sk-ant-test-key", model)
    llm._client = anthropic.AsyncAnthropic(
        api_key="sk-ant-test-key",
        max_retries=0,
        http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    return llm


async def test_request_on_the_wire_and_parsed_answer():
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=message())

    llm = llm_with(handler)
    criteria = await llm.criteria("late night jazz", "Tracks: 34\nGenres: Jazz (6)")
    await llm.aclose()

    assert criteria == sage.SageCriteria(**ANSWER)

    request = seen[0]
    assert request.url.path == "/v1/messages"
    assert "sk-ant-test-key" not in request.content.decode()  # the key travels in a header only
    assert "server-side-fallback-2026-07-01" in request.headers["anthropic-beta"]
    body = json.loads(request.content)
    assert body["model"] == "claude-opus-5-5"
    assert body["fallbacks"] == "default"
    assert body["max_tokens"] == 4000
    assert body["system"] == sage.SYSTEM_PROMPT
    assert "late night jazz" in body["messages"][0]["content"]
    assert "Genres: Jazz (6)" in body["messages"][0]["content"]
    # Structured output: the SDK sends our criteria model as a JSON schema.
    schema = body["output_config"]["format"]
    assert schema["type"] == "json_schema"
    properties = schema["schema"]["properties"]
    assert set(properties) == set(sage.SageCriteria.model_fields)
    assert properties["energy"]["enum"] == ["low", "medium", "high", "any"]
    # Nothing we did not mean to send (sampling parameters are rejected by
    # current models; thinking is left to the model's default).
    assert not {"temperature", "top_p", "top_k", "thinking", "tools"} & set(body)


async def test_models_without_server_side_fallback_use_the_plain_endpoint():
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json=message())

    llm = llm_with(handler, model="claude-haiku-5-5")
    await llm.criteria("x", "y")
    await llm.aclose()

    body = json.loads(seen[0].content)
    assert body["model"] == "claude-haiku-5-5"
    assert "fallbacks" not in body
    assert "server-side-fallback" not in seen[0].headers.get("anthropic-beta", "")


@pytest.mark.parametrize(
    ("status", "error_type", "expected"),
    [
        (401, "authentication_error", "ANTHROPIC_API_KEY was rejected"),
        (404, "not_found_error", "is not available"),
        (429, "rate_limit_error", "rate limited"),
        (529, "overloaded_error", "HTTP 529"),
        (400, "invalid_request_error", "HTTP 400"),
    ],
)
async def test_api_errors_become_sage_errors_without_leaking_the_prompt(
    status, error_type, expected
):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status, json={"type": "error", "error": {"type": error_type, "message": "nope"}}
        )

    llm = llm_with(handler)
    with pytest.raises(sage.SageError, match=expected) as error:
        await llm.criteria("my very private prompt", "catalog")
    await llm.aclose()
    assert "private prompt" not in str(error.value)
    assert "sk-ant" not in str(error.value)


async def test_connection_failure_becomes_a_sage_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route to host")

    llm = llm_with(handler)
    with pytest.raises(sage.SageError, match="could not reach"):
        await llm.criteria("x", "y")
    await llm.aclose()


@pytest.mark.parametrize(
    ("stop_reason", "text"),
    [
        ("refusal", ""),  # declined before writing anything
        ("refusal", "I can't help with that."),
        ("max_tokens", '{"title": "Smoky Late Ni'),  # cut off mid-JSON
    ],
)
async def test_declined_or_truncated_answers_are_sage_errors(stop_reason, text):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=message(stop_reason=stop_reason, text=text))

    llm = llm_with(handler)
    with pytest.raises(sage.SageError, match="declined|incomplete") as error:
        await llm.criteria("x", "y")
    await llm.aclose()
    assert "Smoky" not in str(error.value)  # the model's output is not echoed


async def test_refusal_without_content_is_reported_as_declined():
    def handler(request: httpx.Request) -> httpx.Response:
        body = message(stop_reason="refusal")
        body["content"] = []
        return httpx.Response(200, json=body)

    llm = llm_with(handler)
    with pytest.raises(sage.SageError, match="declined"):
        await llm.criteria("x", "y")
    await llm.aclose()
