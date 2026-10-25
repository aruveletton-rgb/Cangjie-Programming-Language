package cj_zh_search

import std.collection.*
import std.math.*

public class SearchException <: Exception {
    public init(code: String) { super(code) }
}

public struct Document {
    public Document(public let id: String, public let text: String) {}
}

public struct Hit {
    public Hit(public let id: String, public let score: Float64) {}
}

func isHan(r: Rune): Bool {
    let n = UInt32(r)
    return (n >= 0x3400 && n <= 0x9fff) || (n >= 0x20000 && n <= 0x323af) || (n >= 0xf900 && n <= 0xfaff)
}

func isAsciiWord(r: Rune): Bool {
    let n = UInt32(r)
    return (n >= 48 && n <= 57) || (n >= 65 && n <= 90) || (n >= 97 && n <= 122)
}

public class Tokenizer {
    public let version = "longest-han-unigram-bigram-ascii-v1"
    private let words = HashSet<String>()
    private var maxWord: Int64 = 1

    public init(dictionary: Array<String>) {
        for (word in dictionary) {
            let runes = word.toRuneArray()
            if (runes.isEmpty() || runes.size > 64) { throw SearchException("INVALID_CONFIG") }
            for (r in runes) { if (!isHan(r)) { throw SearchException("INVALID_CONFIG") } }
            words.add(word)
            maxWord = max(maxWord, runes.size)
        }
    }

    private func longest(rs: Array<Rune>, start: Int64): Int64 {
        var length = min(maxWord, rs.size - start)
        while (length > 0) {
            if (words.contains(String(rs[start..start + length]))) { return length }
            length--
        }
        return 0
    }

    public func tokenize(text: String): Array<String> {
        if (text.size > 1048576) { throw SearchException("TEXT_TOO_LARGE") }
        let rs = text.toRuneArray()
        let result = ArrayList<String>()
        var i: Int64 = 0
        while (i < rs.size) {
            if (isAsciiWord(rs[i])) {
                let begin = i
                while (i < rs.size && isAsciiWord(rs[i])) { i++ }
                result.add(String(rs[begin..i]).toAsciiLower())
            } else if (isHan(rs[i])) {
                let length = longest(rs, i)
                if (length > 0) {
                    result.add(String(rs[i..i + length]))
                    i += length
                } else {
                    let begin = i
                    i++
                    while (i < rs.size && isHan(rs[i]) && longest(rs, i) == 0) { i++ }
                    for (j in begin..i) {
                        result.add(String(rs[j..j + 1]))
                        if (j + 1 < i) { result.add(String(rs[j..j + 2])) }
                    }
                }
            } else { i++ }
        }
        return result.toArray()
    }
}

struct Posting {
    Posting(let id: String, let frequency: Int64) {}
}

public class SearchIndex {
    private let tokenizer: Tokenizer
    private let k1: Float64
    private let b: Float64
    private var postings = HashMap<String, ArrayList<Posting>>()
    private var lengths = HashMap<String, Int64>()
    private var averageLength: Float64 = 0.0
    public prop documentCount: Int64 { get() { lengths.size } }

    public init(tokenizer: Tokenizer, k1!: Float64 = 1.2, b!: Float64 = 0.75) {
        if (!(k1 > 0.0 && k1 <= 100.0 && b >= 0.0 && b <= 1.0)) {
            throw SearchException("INVALID_CONFIG")
        }
        this.tokenizer = tokenizer
        this.k1 = k1
        this.b = b
    }

    public func build(documents: Array<Document>): Unit {
        if (documents.size > 100000) { throw SearchException("TOO_MANY_DOCUMENTS") }
        let nextPostings = HashMap<String, ArrayList<Posting>>()
        let nextLengths = HashMap<String, Int64>()
        var total: Int64 = 0
        for (doc in documents) {
            if (doc.id.trimAscii().isEmpty() || doc.id.size > 256) { throw SearchException("EMPTY_DOCUMENT_ID") }
            if (nextLengths.contains(doc.id)) { throw SearchException("DUPLICATE_DOCUMENT_ID") }
            let tokens = tokenizer.tokenize(doc.text)
            nextLengths.add(doc.id, tokens.size)
            total += tokens.size
            let frequencies = HashMap<String, Int64>()
            for (token in tokens) { frequencies[token] = (frequencies.get(token) ?? 0) + 1 }
            for ((term, frequency) in frequencies) {
                if (!nextPostings.contains(term)) { nextPostings[term] = ArrayList<Posting>() }
                nextPostings[term].add(Posting(doc.id, frequency))
            }
        }
        postings = nextPostings
        lengths = nextLengths
        averageLength = if (documents.isEmpty()) { 0.0 } else { Float64(total) / Float64(documents.size) }
    }

    public func search(query: String, topK: Int64): Array<Hit> {
        if (topK <= 0 || topK > 10000) { throw SearchException("INVALID_TOP_K") }
        let unique = HashSet<String>()
        let terms = ArrayList<String>()
        for (token in tokenizer.tokenize(query)) { if (unique.add(token)) { terms.add(token) } }
        let scores = HashMap<String, Float64>()
        for (term in terms) {
            if (let Some(list) <- postings.get(term)) {
                let idf = log(1.0 + (Float64(lengths.size - list.size) + 0.5) / (Float64(list.size) + 0.5))
                for (p in list) {
                    let tf = Float64(p.frequency)
                    let norm = tf + k1 * (1.0 - b + b * Float64(lengths[p.id]) / averageLength)
                    scores[p.id] = (scores.get(p.id) ?? 0.0) + idf * tf * (k1 + 1.0) / norm
                }
            }
        }
        // Bounded insertion keeps the requested topK without sorting every candidate.
        let best = ArrayList<Hit>()
        for ((id, score) in scores) {
            let hit = Hit(id, score)
            var position: Int64 = 0
            while (position < best.size && (best[position].score > score ||
                (best[position].score == score && best[position].id < id))) { position++ }
            if (position < topK) {
                best.add(hit, at: position)
                if (best.size > topK) { best.remove(at: best.size - 1) }
            }
        }
        return best.toArray()
    }
}
