# Font-backed text

OCEx 0.3 uses FreeType to read outline fonts and HarfBuzz to shape text, then
constructs native OCCT faces from lines and quadratic/cubic Béziers. Install
FreeType and HarfBuzz development libraries plus pkg-config as described in
[installation](installation.md). The existing OCCT installation needs no rebuild.

Fonts are explicit byte snapshots. There is no system font lookup or fallback.
The package includes Graduate, a varsity-style font under the SIL Open Font
License; its license is in `priv/fonts/Graduate-OFL.txt`.

```elixir
font = File.read!(Path.join(:code.priv_dir(:ocex), "fonts/Graduate-Regular.ttf"))
{:ok, info} = OCEx.font_info(font)
"Graduate" = info.family
{:ok, text} = OCEx.text("TEAM", font, 10)
{:ok, solid} = OCEx.extrude(text.shape, {0, 0, 1})
{:ok, area} = OCEx.area(text.shape)
{:ok, volume} = OCEx.volume(solid)
true = abs(volume - area) < 1.0e-5
IO.inspect(Map.drop(text, [:shape]))
```

`size` is the font's em size in model units; actual letters are usually shorter.
`ink_bounds` measures the resulting BREP. `advance` is typographic horizontal
advance, including spaces. Glyph records contain the font glyph ID, UTF-8 byte
cluster offset, positioned origin, advance and ink bounds. Spaces have no bounds.
Counter holes and separated dots remain geometry; overlapping letters are unioned
before measuring or extruding, so overlapping area is not counted twice.

`tracking:` adds model units between shaped clusters. Nonzero tracking disables
optional ligatures, while required script shaping remains active. `direction:`
accepts `:auto`, `:ltr` or `:rtl`; `language:` accepts a shaping language such as
`"en"`. `face_index:` selects a collection face. Keep the exact font file in the
consumer project and retain its license. Font design, including lowercase glyphs
that resemble capitals in some varsity fonts, determines the resulting outlines.

## Limits and errors

Text is a single horizontal script/direction run. There is no line breaking,
automatic mixed-direction paragraph layout, variable-font axis API, bitmap/color
glyph rendering, or automatic curved-surface wrapping. Font size, glyph placement
and curve coordinates are not screen hinted. Planar text can be transformed and
extruded with ordinary geometry operations.

Missing characters return `:missing_glyph`, never a fallback font or replacement
box. Whitespace-only text returns `:empty_text`. Empty, control-containing,
multiline or invalid UTF-8 text returns `:invalid_text`; malformed fonts return
`:invalid_font`. Non-scalable fonts return `:unsupported_font`. Invalid or
intersecting contours that cannot form valid bounded faces return `:invalid_glyph`.
The limits are 64 MiB of font data, 65,536 UTF-8 bytes and 4,096 shaped glyphs.
Font parsers execute in the NIF process, under the same ownership and execution
rules as other native operations. Font/HarfBuzz objects are released after every
call; returned shapes own their geometry independently.
