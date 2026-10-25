package cj_zh_search

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SearchTests {
    @TestCase
    func unicodeAndLongest() {
        let t = Tokenizer(["社区", "社区活动", "报修"])
        @Expect(t.tokenize("社区活动，报修 ABC12！")[0], "社区活动")
        @Expect(t.tokenize("社区活动，报修 ABC12！")[2], "abc12")
        @Expect(t.tokenize("龘靐").size, 3)
        @Expect(t.tokenize("𠀀𠀁").size, 3)
        @Expect(t.tokenize("🙂， \n").size, 0)
    }

    @TestCase
    func rankAndRebuild() {
        let idx = SearchIndex(Tokenizer(["报修", "社区"]))
        idx.build([Document("b", "报修"), Document("a", "报修"), Document("c", "社区")])
        @Expect(idx.search("报修", 5)[0].id, "a")
        @Expect(idx.search("报修", 5)[1].id, "b")
        @Expect(idx.search("", 5).size, 0)
        @Expect(idx.search("未知词", 5).size, 0)
        var rejected = false
        try { idx.build([Document("x", ""), Document("x", "报修")]) }
        catch (_: SearchException) { rejected = true }
        @Expect(rejected, true)
        @Expect(idx.documentCount, 3)
        idx.build([])
        @Expect(idx.documentCount, 0)
        @Expect(idx.search("报修", 5).size, 0)
    }

    @TestCase
    func inputBoundsAndBm25() {
        let idx = SearchIndex(Tokenizer([]))
        idx.build([Document("short", "alpha"), Document("long", "alpha beta gamma")])
        @Expect(idx.search("ALPHA", 5)[0].id, "short")
        @Expect(idx.search("alpha alpha", 5)[0].score, idx.search("alpha", 5)[0].score)
        var count = 0
        try { idx.search("x", 0) } catch (_: SearchException) { count++ }
        try { idx.build([Document(" ", "")]) } catch (_: SearchException) { count++ }
        try { Tokenizer(["a"]) } catch (_: SearchException) { count++ }
        try { SearchIndex(Tokenizer([]), b: 2.0) } catch (_: SearchException) { count++ }
        @Expect(count, 4)
    }
}
