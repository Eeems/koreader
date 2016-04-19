describe("Readertoc module", function()
    local DocumentRegistry, ReaderUI, DEBUG
    local readerui, toc, toc_max_depth

    setup(function()
        require("commonrequire")
        DocumentRegistry = require("document/documentregistry")
        ReaderUI = require("apps/reader/readerui")
        DEBUG = require("dbg")

        local sample_epub = "spec/front/unit/data/juliet.epub"
        readerui = ReaderUI:new{
            document = DocumentRegistry:openDocument(sample_epub),
        }
        toc = readerui.toc
    end)

    it("should get max toc depth", function()
        toc_max_depth = toc:getMaxDepth()
        assert.are.same(2, toc_max_depth)
    end)
    it("should get toc title from page", function()
        local title = toc:getTocTitleByPage(51)
        DEBUG("toc", toc.toc)
        assert(title == "SCENE V. A hall in Capulet's house.")
        local title = toc:getTocTitleByPage(155)
        assert(title == "SCENE I. Friar Laurence's cell.")
    end)
    describe("getTocTicks API", function()
        local ticks_level_0 = nil
        it("should get ticks of level 0", function()
            ticks_level_0 = toc:getTocTicks(0)
            --DEBUG("ticks", ticks_level_0)
            assert.are.same(28, #ticks_level_0)
        end)
        local ticks_level_1 = nil
        it("should get ticks of level 1", function()
            ticks_level_1 = toc:getTocTicks(1)
            assert.are.same(7, #ticks_level_1)
        end)
        local ticks_level_2 = nil
        it("should get ticks of level 2", function()
            ticks_level_2 = toc:getTocTicks(2)
            assert.are.same(26, #ticks_level_2)
        end)
        local ticks_level_m1 = nil
        it("should get ticks of level -1", function()
            ticks_level_m1 = toc:getTocTicks(-1)
            assert.are.same(26, #ticks_level_m1)
        end)
        it("should get the same ticks of level -1 and level 2", function()
            if toc_max_depth == 2 then
                assert.are.same(ticks_level_2, ticks_level_m1)
            end
        end)
    end)
    it("should get page of next chapter", function()
        assert.are.same(26, toc:getNextChapter(10, 0))
        assert.are.same(102, toc:getNextChapter(100, 0))
        assert.are.same(nil, toc:getNextChapter(200, 0))
    end)
    it("should get page of previous chapter", function()
        assert.are.same(9, toc:getPreviousChapter(10, 0))
        assert.are.same(99, toc:getPreviousChapter(100, 0))
        assert.are.same(186, toc:getPreviousChapter(200, 0))
    end)
    it("should get page left of chapter", function()
        assert.are.same(15, toc:getChapterPagesLeft(10, 0))
        assert.are.same(12, toc:getChapterPagesLeft(102, 0))
        assert.are.same(nil, toc:getChapterPagesLeft(200, 0))
    end)
    it("should get page done of chapter", function()
        assert.are.same(2, toc:getChapterPagesDone(12, 0))
        assert.are.same(0, toc:getChapterPagesDone(99, 0))
        assert.are.same(18, toc:getChapterPagesDone(204, 0))
    end)
    describe("collasible TOC", function()
        it("should collapse the secondary toc nodes by default", function()
            toc:onShowToc()
            assert.are.same(7, #toc.collapsed_toc)
        end)
        it("should not expand toc nodes that have no child nodes", function()
            toc:expandToc(2)
            assert.are.same(7, #toc.collapsed_toc)
        end)
        it("should expand toc nodes that have child nodes", function()
            toc:expandToc(3)
            assert.are.same(13, #toc.collapsed_toc)
            toc:expandToc(18)
            assert.are.same(18, #toc.collapsed_toc)
        end)
        it("should collapse toc nodes that have been expanded", function()
            toc:collapseToc(3)
            assert.are.same(12, #toc.collapsed_toc)
            toc:collapseToc(18)
            assert.are.same(7, #toc.collapsed_toc)
        end)
    end)
end)
