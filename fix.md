# ACP Reasoning Effort Negotiation

Status: Proposed

## Problem

River accepts OpenAI-compatible `reasoning_effort` values and forwards them to
Codex ACP through `session/set_config_option`. The forwarding is currently
blind: River does not inspect the reasoning-effort options advertised by the
new ACP session.

This breaks Zed's **Generate Commit Message** flow. Zed intentionally sends
`reasoning_effort: "none"` when thinking is disabled, while the current Codex
ACP configuration for `gpt-5.6-sol` advertises only:

```text
low, medium, high, xhigh, max, ultra
```

River therefore sends an unsupported ACP option and receives JSON-RPC error
`-32602 Invalid params` before `session/prompt` is called.

## Required Behavior

River must negotiate the requested effort against the options advertised by
Codex ACP for the selected model.

1. Read the `reasoning_effort` select option from `configOptions` returned by
   `session/new`.
2. When River changes the model, replace the cached options with the
   `configOptions` returned by the successful model
   `session/set_config_option` call. This response is authoritative because
   supported efforts may differ between models.
3. Resolve an incoming effort as follows:
   - `nil`: do not call the ACP reasoning-effort config option.
   - An effort advertised by ACP: forward it unchanged.
   - `none` or `minimal`, when not advertised and `low` is advertised: forward
     `low`.
   - Any other unsupported effort: preserve the current
     `unsupported_reasoning_effort` error behavior.
   - Missing or malformed ACP capability metadata: preserve the current
     behavior; do not silently guess a supported value.
4. Apply the same negotiation to Chat Completions and Responses API requests;
   both already converge on the ACP client.
5. Keep the public OpenAI-compatible response shape unchanged. The fallback is
   an internal transport adaptation.

The fallback must be capability-driven. Do not globally rewrite `none` or
`minimal` when ACP explicitly advertises either value.

## Implementation Scope

Keep both River implementations behaviorally aligned:

- `lib/river/codex_acp/client.ex`
- `clear_elixir/lib/codex_river/codex_acp/client.ex`

For each in-flight operation, retain the supported reasoning efforts resolved
from the session response. Do not store model-specific options as global client
state because the client can run concurrent operations with independent ACP
sessions.

Recommended helpers:

```elixir
supported_reasoning_efforts(config_options) :: [String.t()] | :unknown
resolve_reasoning_effort(requested, supported) ::
  String.t() | nil
```

For unsupported values outside the explicit fallback, return the requested
value unchanged and let ACP produce the existing structured error. This keeps
the current error details and HTTP mapping intact.

Do not log the routine `none` or `minimal` fallback to `low`; it can happen on
every request and does not indicate a failure.

## Tests

Extend the fake ACP so `session/new` and model configuration responses expose
realistic `configOptions`. Cover at least:

1. `none` falls back to `low` when ACP advertises `low` but not `none`.
2. `minimal` falls back to `low` under the same conditions.
3. `none` is forwarded unchanged when ACP advertises `none`.
4. `low`, `medium`, `high`, `xhigh`, and `max` are forwarded unchanged when
   advertised.
5. An unsupported non-fallback value keeps returning
   `unsupported_reasoning_effort`.
6. A request without an effort does not send a reasoning config request.
7. A model change uses the updated effort options returned for the new model,
   not the options from `session/new`.
8. The prompt is sent after a successful fallback and is not sent after a
   genuine unsupported-effort error.
9. Chat Completions and Responses HTTP tests both exercise the negotiated
   result.

Relevant test surfaces:

- `test/support/fake_codex_acp.py`
- `test/river/codex_acp/client_test.exs`
- `clear_elixir/test/support/fake_codex_acp.py`
- `clear_elixir/test/codex_river/http/api_test.exs`

## Acceptance Criteria

- Zed Generate Commit Message succeeds through River when it sends
  `reasoning_effort: "none"` to a Codex ACP model whose minimum advertised
  effort is `low`.
- River sends `low`, not `none`, to that ACP session.
- Supported requested efforts retain their exact value.
- River still rejects unsupported values that are not covered by the explicit
  `none`/`minimal` fallback.
- Concurrent requests cannot leak supported-effort metadata across sessions.
- Both River implementations and their tests remain in parity.
- The applicable `mix precommit` checks pass.

## Non-Goals

- Changing Zed configuration or its commit-message prompt.
- Claiming that `low` is semantically identical to disabled reasoning; it is
  the closest effort exposed by the current Codex ACP surface.
- Introducing a general nearest-effort algorithm for arbitrary unsupported
  values.
- Changing the public OpenAI-compatible request or response contract.
