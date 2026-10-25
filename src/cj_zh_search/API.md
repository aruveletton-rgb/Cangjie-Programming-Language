# API 0.1.0

```cangjie
import cj_zh_search.*
let index = SearchIndex(Tokenizer(["社区", "报修"]))
index.build([Document("rule@1", "社区报修先确认")])
let hits = index.search("报修", 5)
```

| API | Behavior |
| --- | --- |
| `Document(id: String, text: String)` | Immutable generic value. ID validated by build, not by construction. |
| `Tokenizer(dictionary: Array<String>)` | Deduplicates Han-only words, 1-64 Unicode scalars each; empty dictionary allowed. |
| `Tokenizer.version: String` | `longest-han-unigram-bigram-ascii-v1`. |
| `tokenize(text: String): Array<String>` | Han ranges 3400-9FFF, F900-FAFF, 20000-323AF. Longest dictionary match; unmatched Han runs emit single scalars and adjacent bigrams. ASCII letters/digits form lowercase tokens. Punctuation, whitespace, symbols/emoji split runs. No normalization beyond ASCII case. |
| `SearchIndex(tokenizer: Tokenizer, k1!: Float64 = 1.2, b!: Float64 = 0.75)` | k1 in (0,100], b in [0,1]; NaN/infinity rejected by bounds. |
| `build(documents: Array<Document>): Unit` | Stages new index and replaces only on success. IDs nonblank, at most 256 UTF-8 bytes and unique. Empty documents count toward N and average length; empty set is valid. Maximum 100000 documents, each text at most 1048576 UTF-8 bytes. |
| `search(query: String, topK: Int64): Array<Hit>` | topK in [1,10000]. Query at most 1048576 UTF-8 bytes. Query terms deduplicated while preserving token order. Empty/no-hit returns empty array. Score descending, ties ID lexicographic ascending. Truncates to available hits. |
| `documentCount: Int64` | Number of documents, including empty text. |
| `Hit.id / Hit.score` | Generic document ID and Float64 score. |
| `SearchException` | message: `INVALID_CONFIG`, `EMPTY_DOCUMENT_ID`, `DUPLICATE_DOCUMENT_ID`, `INVALID_TOP_K`, `TEXT_TOO_LARGE`, `TOO_MANY_DOCUMENTS`. |

BM25: `idf = ln(1 + (N-df+0.5)/(df+0.5))`, term weight `idf * tf*(k1+1)/(tf+k1*(1-b+b*dl/avgdl))`. An all-empty index has no postings, so no division by zero is evaluated. Query duplicate terms contribute once. No business permissions or applicability are part of this library.

Index build is O(total terms) plus dictionary lookup costs; search scans postings for query terms and keeps a bounded topK insertion list. Peak build memory includes the previous and staged indices. Input ceilings prevent individual oversize inputs, not a total-memory guarantee.
