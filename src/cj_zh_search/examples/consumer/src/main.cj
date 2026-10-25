package search_consumer

import cj_zh_search.*

main() {
    let idx = SearchIndex(Tokenizer(["社区", "报修", "活动"]))
    idx.build([Document("repair", "社区报修需要确认"), Document("event", "社区活动报名")])
    let hits = idx.search("报修", 5)
    if (hits.size != 1 || hits[0].id != "repair") { throw Exception("consumer retrieval failed") }
    println("independent-consumer-ok: ${hits[0].id} score=${hits[0].score}")
}
