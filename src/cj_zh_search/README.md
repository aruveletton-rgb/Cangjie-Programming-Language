# cj_zh_search 0.1.0 Local Source Candidate

Pure Cangjie 1.0.5 Chinese text retrieval: Unicode scalar tokenization, longest dictionary matching, unigram/bigram fallback, inverted postings, BM25 and deterministic topK. No network, HTTP, domain fields, filesystem access, credentials, external dictionary or third-party dependency.

```powershell
cjpm build
cjpm test --no-color
cjpm bench --no-color
cd examples/consumer
cjpm run
```

On this Windows SDK, cjpm dependency scanning fails under Chinese absolute paths. Use an ASCII build copy through `../backend/build-library.ps1`. Source and audit remain in the project; system encoding is unchanged. The source archive verifier extracts into a fresh ASCII directory and uses a real local path dependency.

Benchmarks are development measurements: 1000 self-authored synthetic documents, default BM25 parameters, build includes tokenization, query excludes build. The bench runner performs its own warmup and sampling. Hardware, output and timing are in `audit/backend`. These are not blind retrieval tests or AI gains.

See `API.md` for exact behavior. A SearchIndex instance is mutable and not thread-safe; callers synchronize build/search or use independent instances. The service filters business applicability before constructing its index. Scores are ranking values, not probabilities. Dictionary boundaries can reduce recall for unfamiliar compounds; lexical retrieval does not infer semantic equivalence.

This is a local candidate, not a publicly released or licensed package. Read `LICENSE` before any distribution. No `cjpm publish` was attempted.
