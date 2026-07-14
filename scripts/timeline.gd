class_name Timeline
extends Control
## Adobe Animate 式的时间轴控件：自绘 + 自己处理鼠标，不是一排 Button 堆出来的。
##
## 原来那版每一帧是一个 Button，于是播放头拖不动、关键帧挪不了、区间也拉不出来——
## 按钮只会「被点」，不会「被拖」。改成一整块 Control 之后，帧号 ↔ 像素的换算全在自己手里，
## 拖拽、吸附、命中判定想怎么写就怎么写。
##
## 交互（对着 Animate 抄的）：
##   · 拖标尺       = 拖播放头擦帧（scrub），松手也不落关键帧
##   · 拖关键帧     = 把它挪到别的帧（连带它的补间/表情/胯位移一起搬）
##   · 在空白帧拖   = 拉出区间选择（给「创建补间」用）
##   · Shift + 点击 = 把选区拉到这一帧
##   · 右键         = 弹出菜单（插入/删除关键帧、创建/清除补间）
##   · Ctrl + 滚轮  = 缩放帧宽；普通滚轮 = 左右平移
##
## 画法：关键帧 = 实心金圆点，补间区间 = 带箭头的色带（线性暗红 / 缓动蓝紫 / 定格灰），
## 空帧 = 暗格。跟 Animate 一样一眼能看出「哪几帧是关键帧、中间那段在补什么」。

signal scrubbed(frame: float)              # 拖播放头
signal key_moved(from_frame: int, to_frame: int)
signal selection_changed(a: int, b: int)
signal menu_requested(frame: int, screen_pos: Vector2)

const RULER_H := 20.0
const ROW_H := 34.0
const KEY_R := 4.5                         # 关键帧圆点半径
const MIN_CELL := 8.0
const MAX_CELL := 40.0
const HIT_PX := 6.0                        # 拖关键帧的命中半径

const COL_BG := Color(0.07, 0.02, 0.02)
const COL_RULER := Color(0.14, 0.05, 0.05)
const COL_GRID := Color(0.35, 0.28, 0.18, 0.35)
const COL_EMPTY := Color(0.13, 0.05, 0.05)
const COL_KEY := Color(0.85, 0.68, 0.28)
const COL_TWEEN_LINEAR := Color(0.38, 0.12, 0.10)
const COL_TWEEN_EASE := Color(0.22, 0.17, 0.42)
const COL_HOLD := Color(0.26, 0.24, 0.24)
const COL_SEL := Color(0.95, 0.78, 0.35, 0.18)
const COL_PLAYHEAD := Color(0.98, 0.85, 0.55)
const COL_TEXT := Color(0.85, 0.78, 0.62, 0.75)

enum Drag { NONE, SCRUB, KEY, RANGE }

var length := 48
var playhead := 0.0
var keys := {}                             # 帧号 -> 姿势（这里只关心「有没有」）
var spans := {}                            # 补间区间起始帧 -> AnimBaker.Ease
var sel_a := -1
var sel_b := -1
var cell_w := 16.0
var scroll := 0.0                          # 左边被卷出去多少像素

var _drag := Drag.NONE
var _drag_key_from := -1
var _drag_key_to := -1
var _font: Font
var _font_size := 9


func _ready() -> void:
	_font = get_theme_default_font()
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size.y = RULER_H + ROW_H + 8.0


func refresh() -> void:
	queue_redraw()


# ---------------------------------------------------------------- 帧号 ↔ 像素

func frame_to_x(f: float) -> float:
	return f * cell_w - scroll


func x_to_frame(x: float) -> int:
	return clampi(int(floor((x + scroll) / cell_w)), 0, length - 1)


## 播放头跑出视野就把它卷回来（播放时用）
func follow_playhead() -> void:
	var x := frame_to_x(playhead)
	if x < 0.0 or x > size.x - cell_w:
		scroll = clampf(playhead * cell_w - size.x * 0.5, 0.0, maxf(0.0, length * cell_w - size.x))
		queue_redraw()


func _max_scroll() -> float:
	return maxf(0.0, length * cell_w - size.x)


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	draw_rect(Rect2(0, 0, size.x, RULER_H), COL_RULER)

	var first := maxi(0, int(scroll / cell_w))
	var last := mini(length - 1, int((scroll + size.x) / cell_w) + 1)
	var row_y := RULER_H + 2.0

	# 选区底色（画在帧格底下）
	if sel_a >= 0 and sel_b >= 0:
		var lo := mini(sel_a, sel_b)
		var hi := maxi(sel_a, sel_b)
		draw_rect(Rect2(frame_to_x(lo), 0, (hi - lo + 1) * cell_w, size.y), COL_SEL)

	# 帧格
	for f in range(first, last + 1):
		var x := frame_to_x(f)
		draw_rect(Rect2(x + 1.0, row_y, cell_w - 1.0, ROW_H - 4.0), COL_EMPTY)
		# 标尺刻度：每 5 帧一根长线 + 帧号，其余短线
		var is_major := (f + 1) % 5 == 0 or f == 0
		draw_line(Vector2(x, RULER_H - (7.0 if is_major else 4.0)), Vector2(x, RULER_H),
			COL_GRID, 1.0)
		if is_major and cell_w >= 11.0 and _font != null:
			draw_string(_font, Vector2(x + 2.0, RULER_H - 8.0), str(f + 1),
				HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, COL_TEXT)

	_draw_spans(row_y)
	_draw_keys(row_y)
	_draw_playhead()


## 补间区间：两个关键帧之间画一条带箭头的色带（Animate 里那根箭头就是「这段在补间」的标志）
func _draw_spans(row_y: float) -> void:
	var fs := keys.keys()
	fs.sort()
	for i in range(fs.size() - 1):
		var a: int = fs[i]
		var b: int = fs[i + 1]
		if b - a < 2:
			continue                       # 挨着的两帧之间没有补间可画
		var e := int(spans.get(a, 0))     # 0 = AnimBaker.Ease.LINEAR
		var col := COL_TWEEN_LINEAR
		if e == 4:                        # HOLD
			col = COL_HOLD
		elif e != 0:
			col = COL_TWEEN_EASE
		var x0 := frame_to_x(a) + cell_w * 0.5
		var x1 := frame_to_x(b) + cell_w * 0.5
		if x1 < 0.0 or x0 > size.x:
			continue
		draw_rect(Rect2(x0, row_y + 4.0, x1 - x0, ROW_H - 12.0), col)
		if e == 4:
			continue                      # 定格没有「渐变过去」的意思，不画箭头
		var mid := row_y + (ROW_H - 4.0) * 0.5
		draw_line(Vector2(x0 + 3.0, mid), Vector2(x1 - 3.0, mid), Color(1, 1, 1, 0.35), 1.0)
		var tip := Vector2(x1 - 3.0, mid)
		draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-5, -3), tip + Vector2(-5, 3)]),
			Color(1, 1, 1, 0.45))


func _draw_keys(row_y: float) -> void:
	var cy := row_y + (ROW_H - 4.0) * 0.5
	for f in keys:
		var draw_f: int = f
		if _drag == Drag.KEY and int(f) == _drag_key_from:
			draw_f = _drag_key_to        # 拖拽中的关键帧画在它将要落到的位置
		var x := frame_to_x(draw_f) + cell_w * 0.5
		if x < -10.0 or x > size.x + 10.0:
			continue
		draw_circle(Vector2(x, cy), KEY_R, COL_KEY)
		draw_arc(Vector2(x, cy), KEY_R, 0.0, TAU, 12, Color(1, 0.95, 0.8, 0.9), 1.0)
	if _drag == Drag.KEY and _drag_key_to != _drag_key_from:
		# 拖到哪儿了：画一条虚提示线，跟 Animate 一样让你看清落点
		var x := frame_to_x(_drag_key_to) + cell_w * 0.5
		draw_line(Vector2(x, row_y), Vector2(x, row_y + ROW_H - 4.0), COL_KEY, 1.0)


func _draw_playhead() -> void:
	var x := frame_to_x(playhead) + cell_w * 0.5
	if x < -8.0 or x > size.x + 8.0:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), COL_PLAYHEAD, 1.0)
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - 5.0, 0.0), Vector2(x + 5.0, 0.0), Vector2(x, 8.0)]), COL_PLAYHEAD)


# ---------------------------------------------------------------- 交互

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _drag != Drag.NONE:
		_on_motion((event as InputEventMouseMotion).position)


func _on_button(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not mb.pressed:
			return
		var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
		if mb.ctrl_pressed:
			# 缩放：让光标底下那一帧钉住不动（不然一缩放整条轴就跑了，很难受）
			var anchor := (mb.position.x + scroll) / cell_w
			cell_w = clampf(cell_w * (1.15 if up else 1.0 / 1.15), MIN_CELL, MAX_CELL)
			scroll = clampf(anchor * cell_w - mb.position.x, 0.0, _max_scroll())
		else:
			scroll = clampf(scroll + (-cell_w * 3.0 if up else cell_w * 3.0), 0.0, _max_scroll())
		queue_redraw()
		return

	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		menu_requested.emit(x_to_frame(mb.position.x), mb.global_position)
		return

	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	if not mb.pressed:
		if _drag == Drag.KEY and _drag_key_to != _drag_key_from:
			key_moved.emit(_drag_key_from, _drag_key_to)
		_drag = Drag.NONE
		queue_redraw()
		return

	var f := x_to_frame(mb.position.x)
	if mb.position.y < RULER_H:
		_drag = Drag.SCRUB               # 标尺上按下 = 擦帧
		scrubbed.emit(float(f))
		return
	if mb.shift_pressed and sel_a >= 0:
		sel_b = f
		selection_changed.emit(sel_a, sel_b)
		_drag = Drag.RANGE
		queue_redraw()
		return
	if _hit_key(mb.position) == f and keys.has(f):
		_drag = Drag.KEY                 # 按在关键帧圆点上 = 拖着它搬家
		_drag_key_from = f
		_drag_key_to = f
		scrubbed.emit(float(f))
		return
	_drag = Drag.RANGE
	sel_a = f
	sel_b = f
	selection_changed.emit(sel_a, sel_b)
	scrubbed.emit(float(f))


func _on_motion(pos: Vector2) -> void:
	var f := x_to_frame(pos.x)
	match _drag:
		Drag.SCRUB:
			scrubbed.emit(float(f))
		Drag.KEY:
			if f != _drag_key_to:
				_drag_key_to = f
				queue_redraw()
		Drag.RANGE:
			if f != sel_b:
				sel_b = f
				selection_changed.emit(sel_a, sel_b)
				queue_redraw()


## 光标是不是压在某个关键帧的圆点上（返回帧号，没压中返回 -1）
func _hit_key(pos: Vector2) -> int:
	var cy := RULER_H + 2.0 + (ROW_H - 4.0) * 0.5
	if absf(pos.y - cy) > HIT_PX + KEY_R:
		return -1
	for f in keys:
		if absf(pos.x - (frame_to_x(f) + cell_w * 0.5)) <= HIT_PX + KEY_R:
			return int(f)
	return -1
