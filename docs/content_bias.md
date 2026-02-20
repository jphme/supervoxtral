# Local `content_bias` Implementation

Supervoxtral implements local `content_bias` behavior for the open Voxtral Realtime model using trie-based logit boosting.

## Scope

This is an inference-time steering layer. It does not retrain model weights.

## Behavior

1. Bias terms are tokenized under multiple forms (original/lower/capitalized with leading space).
2. Compound split paths are also added (for tokenizer ambiguity in words like `ellamind`).
3. A prefix trie tracks active phrase matches while decoding.
4. Boosting rules:
   - Continuations: raise candidate token to `max_logit + strength`.
   - First-token starts: add `strength * firstTokenFactor`.
5. EOS guard: skip all biasing when EOS is within 5 logits of current max.

## Defaults

```json
{
  "contentBias": [],
  "contentBiasStrength": 5.0,
  "contentBiasFirstTokenFactor": 0.2
}
```

## Supported Aliases

The settings loader accepts both `content` and `context` naming forms:

- `contentBias` / `contextBias` / `content_bias` / `context_bias`
- `contentBiasStrength` / `contextBiasStrength` / `content_bias_strength` / `context_bias_strength`
- `contentBiasFirstTokenFactor` / `contextBiasFirstTokenFactor` / `content_bias_first_token_factor` / `context_bias_first_token_factor`
