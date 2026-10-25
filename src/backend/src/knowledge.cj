package ict_backend

import cj_zh_search.*
import std.collection.*
import std.fs.*
import std.time.*
import stdx.encoding.json.*
import stdx.crypto.digest.*

func contentHash(text: String): String {
    let digest = SHA256()
    digest.write(text.toArray())
    let digits = "0123456789abcdef"
    var result = "sha256:"
    for (b in digest.finish()) {
        let high = Int64(b / 16); let low = Int64(b % 16)
        result += digits[high..high + 1] + digits[low..low + 1]
    }
    return result
}

class Knowledge {
    let dataset: JsonObject
    let tokenizer: Tokenizer

    init(path: String) {
        dataset = JsonValue.fromStr(String.fromUtf8(File.readFrom(path))).asObject()
        if (!dataset["synthetic"].asBool().getValue()) { fail("FORBIDDEN") }
        let dict = ArrayList<String>()
        for (v in array(dataset, "dictionary").getItems()) { dict.add(v.asString().getValue()) }
        tokenizer = Tokenizer(dict.toArray())
        let ids = HashSet<String>()
        let sources = HashMap<String, String>()
        for (v in array(dataset, "sources").getItems()) {
            let source = v.asObject()
            if (str(source, "type") != "synthetic_authored" || str(source, "allowedPurpose") != "local-development-only") { fail("FORBIDDEN") }
            let sourceId = required(source, "sourceId")
            if (sources.contains(sourceId)) { fail("VALIDATION_ERROR") }
            sources[sourceId] = required(source, "domainId")
        }
        for (v in array(dataset, "records").getItems()) {
            let record = v.asObject()
            let key = required(record, "evidenceId") + "@" + required(record, "version")
            let sourceId = required(record, "sourceId")
            if (!ids.add(key) || !sources.contains(sourceId) || (sources.get(sourceId) ?? "") != str(record, "domainId") ||
                str(record, "contentHash") != contentHash(str(record, "content")) || !record["synthetic"].asBool().getValue() ||
                (str(record, "domainId") != "campus-demo" && str(record, "domainId") != "community-demo")) { fail("VALIDATION_ERROR") }
            required(record, "title"); required(record, "content", limit: 20000)
            array(record, "roles"); array(record, "campus")
        }
    }

    func applicable(who: Identity, now: DateTime): Array<JsonObject> {
        let candidates = ArrayList<JsonObject>()
        let matters = HashMap<String, Int64>()
        for (v in array(dataset, "records").getItems()) {
            let r = v.asObject()
            if (str(r, "domainId") == who.domain && has(array(r, "roles"), who.role) &&
                has(array(r, "campus"), who.area) && validAt(r, now)) {
                candidates.add(r)
                let matter = str(r, "matterId")
                matters[matter] = (matters.get(matter) ?? 0) + 1
            }
        }
        let safe = ArrayList<JsonObject>()
        for (r in candidates) { if (matters[str(r, "matterId")] == 1) { safe.add(r) } }
        return safe.toArray()
    }

    func refs(who: Identity, now: DateTime, query: String): JsonArray {
        let candidates = applicable(who, now)
        let queryTerms = tokenizer.tokenize(query)
        let documents = ArrayList<Document>()
        let mapping = HashMap<String, JsonObject>()
        for (r in candidates) {
            let text = str(r, "title") + " " + str(r, "content")
            let terms = HashSet<String>()
            for (term in tokenizer.tokenize(text)) { terms.add(term) }
            var supported = false
            // One shared Han scalar is too weak to authorize even a deterministic rule answer.
            for (term in queryTerms) {
                if (term.toRuneArray().size >= 2 && terms.contains(term)) { supported = true }
            }
            if (!supported) { continue }
            let id = str(r, "evidenceId") + "@" + str(r, "version")
            documents.add(Document(id, text))
            mapping[id] = r
        }
        let index = SearchIndex(tokenizer)
        index.build(documents.toArray())
        let result = JsonArray()
        for (hit in index.search(query, 5)) {
            let ref = copyObject(mapping[hit.id])
            ref.put("score", JsonFloat(hit.score))
            result.add(ref)
        }
        return result
    }

    func evidence(who: Identity, now: DateTime, kind: String): JsonArray {
        let result = JsonArray()
        for (r in applicable(who, now)) { if (str(r, "kind") == kind) { result.add(copyObject(r)) } }
        if (result.size() != 1) { fail("EVIDENCE_NOT_APPLICABLE") }
        return result
    }

    func snapshotCurrent(refs: JsonArray, who: Identity, now: DateTime, kind: String): Bool {
        let current = evidence(who, now, kind)
        if (refs.size() != current.size()) { return false }
        for (i in 0..refs.size()) {
            let old = refs[i].asObject(); let next = current[i].asObject()
            for (key in ["evidenceId", "version", "contentHash", "sourceId"]) {
                if (str(old, key) != str(next, key)) { return false }
            }
        }
        return true
    }
}
