package cj_zh_search

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SearchBenchmarks {
    let idx = SearchIndex(Tokenizer(["社区", "报修", "活动", "材料"]))

    init() {
        idx.build(Array<Document>(1000, {i => Document("doc-${i}", "社区报修需要地点材料确认 社区活动 ${i}")}))
    }

    @Bench
    func query1000() {
        idx.search("社区报修材料", 5)
    }

    @Bench
    func build1000() {
        let next = SearchIndex(Tokenizer(["社区", "报修"]))
        next.build(Array<Document>(1000, {i => Document("doc-${i}", "社区报修需要用户确认 ${i}")}))
    }
}
