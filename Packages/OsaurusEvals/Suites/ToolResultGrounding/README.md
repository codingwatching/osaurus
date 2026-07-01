# ToolResultGrounding suite

Pure-data transcript checks for model/tool reliability artifacts. Each case
freezes a tool-call/result/final-answer sequence and asserts that the final
answer uses fragments from the named tool result, not tool-call arguments.

This suite does not call a model and does not touch UI. It is meant to make
runtime proof rows reviewable after a live run has produced a transcript-shaped
artifact.

## Running

```bash
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/ToolResultGrounding \
  --model auto
```

`--model` is ignored by the scorer; `auto` keeps local configuration unchanged.

## Case schema

Use `expect.toolResultGrounding.events` to list `toolCall`, `toolResult`, and
`assistant` events in transcript order. Use `assertions` to bind a final-answer
fragment to the result `callId` it must come from.

Important fields:

- `answerMustContain`: fragments that must appear in the final answer and in
  the named tool result, and must not already appear in the matching tool-call
  arguments.
- `answerMustNotContain`: stale or fabricated fragments that must stay out of
  the final answer.
- `resultMustContain`: fragments that must be present in the tool result.
- `argumentsMustNotContain`: fragments that must not have been available in the
  original tool-call arguments.
