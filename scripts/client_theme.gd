class_name ClientTheme
extends RefCounted
## 客户端统一皮肤（暗红 + 金边，参考素材风格）：登录页 / 捏脸换装页共用的样式工具。

const PANEL := Color(0.23, 0.055, 0.055, 0.94)
const PANEL_DARK := Color(0.13, 0.032, 0.032, 0.96)
const PANEL_GLASS := Color(0.10, 0.025, 0.025, 0.78)
const GOLD := Color("d8b46a")
const GOLD_DIM := Color("9a7d4a")
const RED := Color("d84545")
const TEXT := Color("e8d9b8")
const TEXT_DIM := Color(0.91, 0.85, 0.72, 0.55)


static func make_theme() -> Theme:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"])
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 15
	return t


# ---- 功能窗口统一尺寸（以任务窗口为准，略放大；好友窗口除外，保持自身尺寸）
const WIN_W := 960.0
const WIN_H := 600.0

# ---- 游戏内 HUD 皮肤（暗红金边，和登录页/工房统一；大世界 / 背包共用）
const TECH_EDGE := Color(0.847, 0.706, 0.416, 0.85)   # 金边
const TECH_BG := Color(0.13, 0.032, 0.032, 0.82)      # 暗红底
const TECH_TEXT := Color(0.91, 0.85, 0.72)            # 米金文字
const ACCENT := Color(0.93, 0.74, 0.38)               # 亮金强调


static func tech_style(bg := TECH_BG, edge := TECH_EDGE, bw := 1, radius := 4) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(bw)
	sb.border_color = edge
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


static func panel_style(bg := PANEL, border := GOLD_DIM, bw := 2, radius := 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(bw)
	sb.border_color = border
	sb.set_corner_radius_all(radius)
	return sb


static func style_button(btn: Button, font_size: int, accent := false) -> void:
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", GOLD)
	btn.add_theme_color_override("font_hover_color", Color("f2dfae"))
	btn.add_theme_color_override("font_pressed_color", GOLD)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("8c1a1a") if accent else Color("6d1414")
	sb.set_border_width_all(2)
	sb.border_color = Color("e6c87d") if accent else GOLD
	sb.set_corner_radius_all(8)
	btn.add_theme_stylebox_override("normal", sb)
	var sb_hover := sb.duplicate()
	sb_hover.bg_color = Color("a82020") if accent else Color("8c1a1a")
	btn.add_theme_stylebox_override("hover", sb_hover)
	var sb_press := sb.duplicate()
	sb_press.bg_color = Color("511010")
	btn.add_theme_stylebox_override("pressed", sb_press)


## 页签按钮：选中态金底红字
static func style_tab_button(btn: Button, font_size: int) -> void:
	style_button(btn, font_size)
	var sb_on := StyleBoxFlat.new()
	sb_on.bg_color = GOLD
	sb_on.set_border_width_all(2)
	sb_on.border_color = Color("e6c87d")
	sb_on.set_corner_radius_all(8)
	btn.add_theme_stylebox_override("pressed", sb_on)
	btn.add_theme_color_override("font_pressed_color", Color("511010"))


static func style_line_edit(le: LineEdit) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.022, 0.022)
	sb.set_border_width_all(1)
	sb.border_color = GOLD_DIM
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	le.add_theme_stylebox_override("normal", sb)
	var sb_focus := sb.duplicate()
	sb_focus.border_color = GOLD
	le.add_theme_stylebox_override("focus", sb_focus)


## 骨骼树等 Tree 控件的暗红金边皮肤（Tree 默认是浅色，不覆盖会很跳）
static func style_tree(tree: Tree) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.07, 0.018, 0.018, 0.9)
	bg.set_border_width_all(1)
	bg.border_color = Color(GOLD_DIM, 0.6)
	bg.set_corner_radius_all(4)
	tree.add_theme_stylebox_override("panel", bg)
	tree.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var sel := StyleBoxFlat.new()
	sel.bg_color = Color(0.55, 0.36, 0.10, 0.75)
	sel.set_corner_radius_all(3)
	tree.add_theme_stylebox_override("selected", sel)
	tree.add_theme_stylebox_override("selected_focus", sel)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.35, 0.12, 0.10, 0.6)
	hover.set_corner_radius_all(3)
	tree.add_theme_stylebox_override("hovered", hover)
	tree.add_theme_color_override("font_color", TEXT)
	tree.add_theme_color_override("font_selected_color", Color("fff0d0"))
	tree.add_theme_color_override("guide_color", Color(GOLD_DIM, 0.25))
	tree.add_theme_color_override("children_hl_line_color", Color(GOLD_DIM, 0.5))
	tree.add_theme_color_override("parent_hl_line_color", Color(GOLD, 0.6))
	tree.add_theme_color_override("relationship_line_color", Color(GOLD_DIM, 0.35))
	tree.add_theme_font_size_override("font_size", 13)
	tree.add_theme_constant_override("draw_relationship_lines", 1)
	tree.add_theme_constant_override("v_separation", 3)


## 金边圆角牌匾（顶部标题等）
static func plaque(text: String, pos: Vector2, plaque_size: Vector2, parent: Control) -> void:
	var p := PanelContainer.new()
	p.position = pos
	p.custom_minimum_size = plaque_size
	var sb := panel_style(PANEL_DARK, GOLD, 1, int(plaque_size.y / 2.0))
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	p.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", GOLD)
	lbl.add_theme_font_size_override("font_size", 17)
	p.add_child(lbl)
	parent.add_child(p)


## 屏幕四周金色双线框
static func screen_frame(parent: Control) -> void:
	for cfg in [[8.0, 2, Color(GOLD_DIM, 0.9)], [16.0, 1, Color(GOLD_DIM, 0.45)]]:
		var p := Panel.new()
		p.set_anchors_preset(Control.PRESET_FULL_RECT)
		p.offset_left = cfg[0]
		p.offset_top = cfg[0]
		p.offset_right = -cfg[0]
		p.offset_bottom = -cfg[0]
		var sb := panel_style(Color.TRANSPARENT, cfg[2], cfg[1], 0)
		p.add_theme_stylebox_override("panel", sb)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parent.add_child(p)
