colors = {}
for index, name in ipairs({"white","orange","magenta","lightBlue","yellow","lime","pink","gray","lightGray",
    "cyan","purple","blue","brown","green","red","black"}) do colors[name] = 2^(index-1) end
local core = dofile("lib/core.lua")
local css = dofile("lib/awesome/css.lua")
local parse = dofile("lib/html.lua")(core)
local layout = dofile("lib/awesome/layout.lua")(css, core)
local view = dofile("lib/awesome/view.lua")
local fonts = dofile("assets/fonts/metrics.lua")
local fixture = assert(io.open("tests/fixtures/awesome.html", "r"))
local html = fixture:read("*a")
fixture:close()
local document = {root=parse.parseHTML(html), stylesheets={html:match("<style>(.-)</style>")}, baseUrl="file:///awesome.html"}
local resources = {measure=function(text, style) return #text*math.ceil(style.size/2), math.ceil(style.size) end,
    image=function() end}

local function findWord(page, text)
    for _, word in ipairs(page.words) do if word.text == text then return word end end
    error("Could not find " .. text)
end
local wide = assert(layout(document, 306, 155, 1, resources))
local small = assert(layout(document, 220, 155, 1, resources))
local zoom = assert(layout(document, 306, 155, 1.5, resources))
assert(wide.background == 0xECDDCB)
assert(findWord(wide, "Trail").style.color == 0xFFFFFF)
assert(findWord(wide, "First").style.color == 0x1C6572)
assert(findWord(wide, "After").style.color == 0x74496A)
assert(findWord(wide, "First").y == findWord(wide, "After").y)
assert(findWord(small, "First").y < findWord(small, "After").y)
assert(findWord(zoom, "First").y < findWord(zoom, "After").y)
assert(wide.anchors.map > findWord(wide, "After").y)
assert(findWord(wide, "map").href == "about:blank")
assert(layout({root=parse.parseHTML("<form><input name='q'></form>")}, 306,155,1,resources) == nil)
assert(css.color("#3AF") == 0x33AAFF and css.color("rgba(255,0,0,0.5)", 0) == 0x800000)
assert(css.length("25%", 200, 12, 1, 300, 160) == 50)
local code = assert(layout({root=parse.parseHTML("<pre>line\n    indent</pre>")}, 306,155,1,resources))
assert(findWord(code, "indent").x > findWord(code, "line").x)
assert(findWord(code, "indent").y > findWord(code, "line").y)

local shapes, placed, ink = 0, {}, {}
local function noop() end
local screen = {
    setClip=noop, resetClip=noop, setPaletteColor=function(i,rgb) ink[i]=rgb end, fillCircle=noop,
    fillRect=function() shapes=shapes+1 end,
    measureText=function(text, style) return #text*5, style.size end,
    loadFont=function(path, options)
        assert(path:match("%.png$") and options.glyphs[63] and options.glyphs[8212])
        return {}
    end,
    text=function(x,y,text,style)
        placed[#placed+1]={x=x,y=y,text=text,color=ink[style.color]}
    end,
}
local browserView = view(fonts,"assets/fonts",layout,screen)
local tab = {document=document}
local page = assert(browserView.prepare(tab,306,150,100))
browserView.render(tab,306,150,26,false)
local plain, plainCount = placed, shapes
placed, shapes = {}, 0
browserView.selectAll(tab)
assert(browserView.text(tab):find("Trail journal",1,true))
browserView.render(tab,306,150,26,true)
assert(shapes > plainCount and #plain == #placed)
for i,item in ipairs(placed) do
    assert(item.text == plain[i].text and item.x == plain[i].x and item.y == plain[i].y,
        "caret mode must retain graphical layout")
end
local link = findWord(page, "Open")
assert(browserView.pointer(tab,"mouse_click",1,link.x,link.y,306,150,false) == "about:blank")
page = assert(browserView.prepare(tab,220,60,100))
browserView.pointer(tab,"mouse_click",1,218,55,220,60,false)
assert(tab.awesomeScroll > 0)
browserView.pointer(tab,"mouse_scroll",-12,100,40,220,60,false)
assert(tab.awesomeScroll == 0)
local imagePage = assert(layout({
    root=parse.parseHTML('<img src="file:///image.png" style="width:50%">'),
    baseUrl="file:///awesome.html",
}, 306, 155, 1, {measure=resources.measure,image=function() return {}, 512, 256 end}))
assert(imagePage.commands[1].kind == "image" and imagePage.commands[1].w == 153)
print("Awesome layout tests passed")
