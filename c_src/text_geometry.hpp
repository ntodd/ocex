// Included inside the NIF's anonymous namespace. Font objects live only for one
// serialized dirty call; no FT/HB pointer escapes into an Erlang resource.
struct TextFont {
  FT_Library library = nullptr;
  FT_Face face = nullptr;
  hb_blob_t *blob = nullptr;
  hb_face_t *hb_face = nullptr;
  hb_font_t *font = nullptr;
  hb_buffer_t *buffer = nullptr;
  void load(const std::string &bytes, int face_index) {
    require(!bytes.empty() && bytes.size() <= 64 * 1024 * 1024 && face_index >= 0, "invalid_font");
    require(FT_Init_FreeType(&library) == 0, "font_engine_failed");
    require(FT_New_Memory_Face(library, reinterpret_cast<const FT_Byte *>(bytes.data()),
                               static_cast<FT_Long>(bytes.size()), face_index, &face) == 0,
            "invalid_font");
    require(FT_IS_SCALABLE(face) && face->units_per_EM > 0, "unsupported_font");
    require(FT_Select_Charmap(face, FT_ENCODING_UNICODE) == 0, "unsupported_font");
  }
  ~TextFont() {
    if (buffer)
      hb_buffer_destroy(buffer);
    if (font)
      hb_font_destroy(font);
    if (hb_face)
      hb_face_destroy(hb_face);
    if (blob)
      hb_blob_destroy(blob);
    if (face)
      FT_Done_Face(face);
    if (library)
      FT_Done_FreeType(library);
  }
};
Term font_info(ErlNifEnv *env, const std::vector<Term> &args) {
  auto bytes = string(env, args[0]);
  int index;
  require(enif_get_int(env, args[1], &index) && index >= 0);
  TextFont owner;
  owner.load(bytes, index);
  return map(env, {{"family", binary(env, owner.face->family_name ? owner.face->family_name : "")},
                   {"style", binary(env, owner.face->style_name ? owner.face->style_name : "")},
                   {"units_per_em", enif_make_uint(env, owner.face->units_per_EM)},
                   {"face_count", enif_make_long(env, owner.face->num_faces)},
                   {"glyph_count", enif_make_long(env, owner.face->num_glyphs)}});
}
struct TextOutline {
  double scale, x, y;
  gp_Pnt first, last;
  std::unique_ptr<BRepBuilderAPI_MakeWire> wire;
  std::vector<TopoDS_Wire> wires;
  std::exception_ptr failure;
  gp_Pnt point(const FT_Vector *v) const {
    return gp_Pnt(x + v->x * scale, y + v->y * scale, 0);
  }
  void line(const gp_Pnt &to) {
    if (last.Distance(to) > Precision::Confusion()) {
      BRepBuilderAPI_MakeEdge edge(last, to);
      require(edge.IsDone(), "invalid_glyph");
      wire->Add(edge.Edge());
      require(wire->IsDone(), "invalid_glyph");
    }
    last = to;
  }
  void close() {
    if (!wire)
      return;
    line(first);
    require(wire->IsDone(), "invalid_glyph");
    wires.push_back(wire->Wire());
    wire.reset();
  }
  void curve(const std::vector<gp_Pnt> &points) {
    TColgp_Array1OfPnt poles(1, static_cast<int>(points.size()));
    for (size_t i = 0; i < points.size(); ++i)
      poles.SetValue(static_cast<int>(i + 1), points[i]);
    Handle(Geom_BezierCurve) curve = new Geom_BezierCurve(poles);
    BRepBuilderAPI_MakeEdge edge(curve);
    require(edge.IsDone(), "invalid_glyph");
    wire->Add(edge.Edge());
    require(wire->IsDone(), "invalid_glyph");
    last = points.back();
  }
  template <typename F> static int guarded(void *context, F action) {
    auto &outline = *static_cast<TextOutline *>(context);
    try {
      action(outline);
      return 0;
    } catch (...) {
      outline.failure = std::current_exception();
      return 1;
    }
  }
  static int move(const FT_Vector *to, void *context) {
    return guarded(context, [&](TextOutline &o) {
      o.close();
      o.first = o.last = o.point(to);
      o.wire = std::make_unique<BRepBuilderAPI_MakeWire>();
    });
  }
  static int line_to(const FT_Vector *to, void *context) {
    return guarded(context, [&](TextOutline &o) { o.line(o.point(to)); });
  }
  static int conic(const FT_Vector *control, const FT_Vector *to, void *context) {
    return guarded(context,
                   [&](TextOutline &o) { o.curve({o.last, o.point(control), o.point(to)}); });
  }
  static int cubic(const FT_Vector *a, const FT_Vector *b, const FT_Vector *to, void *context) {
    return guarded(context,
                   [&](TextOutline &o) { o.curve({o.last, o.point(a), o.point(b), o.point(to)}); });
  }
};
Term text_bounds(ErlNifEnv *env, const TopoDS_Shape &shape) {
  Bnd_Box bounds;
  BRepBndLib::AddOptimal(shape, bounds, false, false);
  if (bounds.IsVoid())
    return atom(env, "nil");
  return enif_make_tuple2(env, point(env, bounds.CornerMin()), point(env, bounds.CornerMax()));
}
Term text_geometry(ErlNifEnv *env, const std::vector<Term> &args) {
  auto text = string(env, args[0]);
  auto bytes = string(env, args[1]);
  require(!text.empty() && text.size() <= 65536 && text.find('\0') == std::string::npos,
          "invalid_text");
  require(!bytes.empty() && bytes.size() <= 64 * 1024 * 1024, "invalid_font");
  double size = positive(env, args[2]), tracking = scalar(env, args[3]);
  int face_index;
  require(enif_get_int(env, args[4], &face_index) && face_index >= 0);
  auto direction = string(env, args[5]);
  auto language = string(env, args[6]);
  require(direction == "auto" || direction == "ltr" || direction == "rtl");
  TextFont owner;
  owner.load(bytes, face_index);
  auto face = owner.face;
  double scale = size / face->units_per_EM;
  owner.blob = hb_blob_create(bytes.data(), static_cast<unsigned>(bytes.size()),
                              HB_MEMORY_MODE_READONLY, nullptr, nullptr);
  owner.hb_face = hb_face_create(owner.blob, static_cast<unsigned>(face_index));
  owner.font = hb_font_create(owner.hb_face);
  hb_ot_font_set_funcs(owner.font);
  hb_font_set_scale(owner.font, face->units_per_EM, face->units_per_EM);
  owner.buffer = hb_buffer_create();
  hb_buffer_add_utf8(owner.buffer, text.data(), static_cast<int>(text.size()), 0,
                     static_cast<int>(text.size()));
  if (direction != "auto")
    hb_buffer_set_direction(owner.buffer, direction == "ltr" ? HB_DIRECTION_LTR : HB_DIRECTION_RTL);
  if (!language.empty())
    hb_buffer_set_language(owner.buffer, hb_language_from_string(language.c_str(), -1));
  hb_buffer_guess_segment_properties(owner.buffer);
  hb_feature_t features[2];
  unsigned feature_count = 0;
  if (tracking != 0) {
    hb_feature_from_string("liga=0", -1, &features[feature_count++]);
    hb_feature_from_string("clig=0", -1, &features[feature_count++]);
  }
  hb_shape(owner.font, owner.buffer, features, feature_count);
  require(hb_buffer_allocation_successful(owner.buffer), "out_of_memory");
  unsigned count;
  auto info = hb_buffer_get_glyph_infos(owner.buffer, &count);
  auto positions = hb_buffer_get_glyph_positions(owner.buffer, nullptr);
  require(count > 0 && count <= 4096, "invalid_text");
  std::vector<TopoDS_Shape> shapes;
  std::vector<Term> glyphs;
  double pen_x = 0, pen_y = 0;
  FT_Outline_Funcs callbacks{
      TextOutline::move, TextOutline::line_to, TextOutline::conic, TextOutline::cubic, 0, 0};
  for (unsigned i = 0; i < count; ++i) {
    require(info[i].codepoint != 0, "missing_glyph");
    require(FT_Load_Glyph(face, info[i].codepoint,
                          FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP) == 0,
            "invalid_glyph");
    require(face->glyph->format == FT_GLYPH_FORMAT_OUTLINE, "unsupported_font");
    double x = pen_x + positions[i].x_offset * scale, y = pen_y + positions[i].y_offset * scale;
    double advance = positions[i].x_advance * scale;
    if (i + 1 < count && info[i].cluster != info[i + 1].cluster)
      advance += tracking;
    Term bounds = atom(env, "nil");
    if (face->glyph->outline.n_contours > 0) {
      TextOutline outline{};
      outline.scale = scale;
      outline.x = x;
      outline.y = y;
      auto status = FT_Outline_Decompose(&face->glyph->outline, &callbacks, &outline);
      if (outline.failure)
        std::rethrow_exception(outline.failure);
      require(status == 0, "invalid_glyph");
      outline.close();
      BRepAlgo_FaceRestrictor restrictor;
      restrictor.Init(BRepBuilderAPI_MakeFace(gp_Pln(gp_Pnt(0, 0, 0), gp_Dir(0, 0, 1))).Face(),
                      true, true);
      for (auto &wire : outline.wires)
        restrictor.Add(wire);
      restrictor.Perform();
      require(restrictor.IsDone(), "invalid_glyph");
      std::vector<TopoDS_Shape> regions;
      for (; restrictor.More(); restrictor.Next())
        regions.push_back(restrictor.Current());
      require(!regions.empty(), "invalid_glyph");
      auto glyph = collection(regions);
      require(BRepCheck_Analyzer(glyph).IsValid(), "invalid_glyph");
      bounds = text_bounds(env, glyph);
      shapes.push_back(glyph);
    }
    glyphs.push_back(map(env, {{"glyph_id", enif_make_uint(env, info[i].codepoint)},
                               {"cluster", enif_make_uint(env, info[i].cluster)},
                               {"origin", point(env, gp_Pnt(x, y, 0))},
                               {"advance", number(env, advance)},
                               {"bounds", bounds}}));
    pen_x += advance;
    pen_y += positions[i].y_advance * scale;
  }
  require(!shapes.empty(), "empty_text");
  // Union outlines so overlapping glyphs never double-count area or extrusion.
  auto result = shapes.front();
  for (size_t i = 1; i < shapes.size(); ++i)
    result = boolean<BRepAlgoAPI_Fuse>(result, shapes[i]);
  require(BRepCheck_Analyzer(result).IsValid(), "invalid_glyph");
  return map(env, {{"shape", resource(env, result)},
                   {"glyphs", list(env, glyphs)},
                   {"advance", number(env, pen_x)},
                   {"ink_bounds", text_bounds(env, result)},
                   {"ascender", number(env, face->ascender * scale)},
                   {"descender", number(env, face->descender * scale)},
                   {"line_height", number(env, face->height * scale)},
                   {"units_per_em", enif_make_uint(env, face->units_per_EM)},
                   {"family", binary(env, face->family_name ? face->family_name : "")},
                   {"style", binary(env, face->style_name ? face->style_name : "")},
                   {"direction",
                    binary(env, hb_direction_to_string(hb_buffer_get_direction(owner.buffer)))}});
}
