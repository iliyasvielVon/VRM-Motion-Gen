# -*- coding: utf-8 -*-
"""多相机实测诊断：跑着它，手机先连一台、过一会再连第二台，逐帧记录到 JSONL。

记什么（对应「抖动 + 时间戳不匹配」两个问题）：
  y=f  每一帧到达：相机、到帧间隔 dt、MediaPipe 推理耗时 det、认没认出人 p、
       该相机自己的原始检测抖动 rd（同机相邻两帧关键点平均位移，米）
  y=x  每一轮融合（30Hz）：参与的相机、**每台数据的年龄 ages**（融合那一刻它最新
       一帧有多旧——双机的年龄差就是时间戳错位）、融合输出的帧间跳动 d（毫米）
  y=e  事件：接入/标定/启用/下线

    python tools/mocap/diag_rig.py                # 采集（Ctrl+C 停），同时照常喂 Godot
    python tools/mocap/diag_rig.py --report 文件   # 离线出报告
"""

import argparse
import json
import socket
import sys
import threading
import time
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture  # noqa: E402
import mediapipe as mp  # noqa: E402
import phone  # noqa: E402
from rig import Rig, _np_pose  # noqa: E402

DEFAULT_LOG = str(Path(__file__).resolve().parent / "rig_diag.jsonl")


def collect(log_path):
    logf = open(log_path, "w", encoding="utf-8")
    llock = threading.Lock()
    t0 = time.monotonic()

    def log(obj):
        with llock:
            logf.write(json.dumps(obj, ensure_ascii=False) + "\n")
            logf.flush()

    def on_event(msg):
        print("[融合] " + msg, flush=True)
        log({"y": "e", "t": round(time.monotonic() - t0, 3), "msg": msg})

    rig = Rig(on_event=on_event)
    marks = {}
    prev_raw = {}
    last_arrive = {}
    ts_last = {}

    def on_frame(cid, jpeg):
        t_in = time.monotonic()
        bgr = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
        if bgr is None:
            return
        if cid not in marks:
            marks[cid] = capture.make_landmarker()
        ms = max(int((t_in - t0) * 1000), ts_last.get(cid, -1) + 1)
        ts_last[cid] = ms
        t_det = time.monotonic()
        res = marks[cid].detect_for_video(
            mp.Image(image_format=mp.ImageFormat.SRGB,
                     data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)), ms)
        det_ms = (time.monotonic() - t_det) * 1000.0
        pk = capture.pack(res)
        rig.push(cid, pk)
        rd = None
        if pk["pose"]:
            pts, _ = _np_pose(pk["pose"])
            if cid in prev_raw:
                rd = float(np.linalg.norm(pts - prev_raw[cid], axis=1).mean())
            prev_raw[cid] = pts
        log({"y": "f", "c": cid, "t": round(t_in - t0, 4),
             "dt": round(t_in - last_arrive.get(cid, t_in), 4),
             "det": round(det_ms, 1), "p": bool(pk["pose"]),
             "rd": round(rd, 4) if rd is not None else None})
        last_arrive[cid] = t_in

    phone.serve_threaded(on_frame, on_close=lambda cid: rig.offline(cid, "手机断开"))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = ("127.0.0.1", 9977)
    print("[诊断] 记录到 %s ｜ 融合照常喂 UDP 9977（Godot 可同时观看）" % log_path, flush=True)

    prev_pts = None
    n_tick = 0
    try:
        while True:
            tick = time.monotonic()
            fused, status = rig.fuse()
            now = time.monotonic()
            ages = {}
            on_ids = []
            for cid, cam in list(rig.cams.items()):
                ages[cid] = round(now - cam.t, 3)
                if cam.state == "on" and now - cam.t < 0.35:
                    on_ids.append(cid)
            d = None
            if fused is not None and fused.get("pose"):
                fused["rig"] = status
                sock.sendto(json.dumps(fused, separators=(",", ":")).encode("utf-8"), addr)
                pts = np.array([p[:3] for p in fused["pose"]])
                if prev_pts is not None:
                    d = float(np.linalg.norm(pts - prev_pts, axis=1).mean() * 1000.0)
                prev_pts = pts
            elif fused is None:
                prev_pts = None
            log({"y": "x", "t": round(now - t0, 3), "on": on_ids, "ages": ages,
                 "d": round(d, 2) if d is not None else None})
            n_tick += 1
            if n_tick % 150 == 0:                    # 每 5 秒一行现场摘要
                print("[诊断] t=%.0fs 在线%s 年龄%s 抖动 %s mm"
                      % (now - t0, on_ids, ages, ("%.1f" % d) if d else "-"), flush=True)
            time.sleep(max(0.0, 1.0 / 30.0 - (time.monotonic() - tick)))
    except KeyboardInterrupt:
        pass
    logf.close()


def pct(v, q):
    return float(np.percentile(v, q)) if len(v) else 0.0


def report(log_path):
    frames = {}
    ticks = []
    events = []
    for line in open(log_path, encoding="utf-8"):
        o = json.loads(line)
        if o["y"] == "f":
            frames.setdefault(o["c"], []).append(o)
        elif o["y"] == "x":
            ticks.append(o)
        else:
            events.append(o)

    print("=" * 66)
    print("事件时间轴")
    for e in events:
        print("  %7.1fs  %s" % (e["t"], e["msg"]))

    print("\n每台相机：到帧节奏 / 推理耗时 / 原始检测抖动")
    for cid, fs in frames.items():
        dts = [f["dt"] for f in fs[1:] if f["dt"] > 0]
        det = [f["det"] for f in fs]
        rds = [f["rd"] for f in fs if f.get("rd") is not None]
        hit = sum(1 for f in fs if f["p"])
        span = fs[-1]["t"] - fs[0]["t"] if len(fs) > 1 else 0
        print("  %s：%d 帧 / %.0fs（≈%.1f fps）｜认出人 %d%%" % (
            cid, len(fs), span, len(fs) / max(span, 1e-9), 100 * hit / max(1, len(fs))))
        if dts:
            print("     到帧间隔  中位 %3.0f ms   p95 %3.0f ms   最大 %4.0f ms   >200ms 的断档 %d 次"
                  % (1000 * pct(dts, 50), 1000 * pct(dts, 95), 1000 * max(dts),
                     sum(1 for d in dts if d > 0.2)))
        if det:
            print("     推理耗时  中位 %3.0f ms   p95 %3.0f ms" % (pct(det, 50), pct(det, 95)))
        if rds:
            print("     原始抖动  中位 %.1f mm/帧   p95 %.1f mm/帧"
                  % (1000 * pct(rds, 50), 1000 * pct(rds, 95)))

    # 按在线相机数分阶段：单机 vs 双机 —— 这是「多目是否更抖」的直接对比
    print("\n融合输出的抖动（帧间跳动，毫米）——按同时在线的相机数分段")
    for n in [1, 2, 3]:
        ds = [t["d"] for t in ticks if t["d"] is not None and len(t["on"]) == n]
        if not ds:
            continue
        print("  %d 台在线：%5d 个采样 ｜ 中位 %5.2f ｜ p95 %5.2f ｜ 最大 %6.2f"
              % (n, len(ds), pct(ds, 50), pct(ds, 95), max(ds)))
    spikes = sorted([t for t in ticks if t["d"] is not None],
                    key=lambda t: -t["d"])[:5]
    print("  最大的 5 次跳动：")
    for t in spikes:
        print("    t=%7.1fs  %6.2f mm  在线=%s  年龄=%s" % (t["t"], t["d"], t["on"], t["ages"]))

    # 时间戳错位：双机同时在线时，两路数据的年龄差
    print("\n时间戳错位（双机同时在线时，两路最新数据的年龄差，毫秒）")
    skews = []
    for t in ticks:
        if len(t["on"]) >= 2:
            a = [t["ages"][c] for c in t["on"]]
            skews.append((max(a) - min(a)) * 1000)
    if skews:
        print("  %d 个采样 ｜ 中位 %.0f ms ｜ p95 %.0f ms ｜ 最大 %.0f ms"
              % (len(skews), pct(skews, 50), pct(skews, 95), max(skews)))
        print("  （对照：融合的新鲜度窗口是 350ms，年龄差在窗口内会被「年龄权重」平滑消化）")
    else:
        print("  （没有双机同时在线的时段）")
    print("=" * 66)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=DEFAULT_LOG)
    ap.add_argument("--report", help="对已有日志出报告")
    args = ap.parse_args()
    if args.report:
        report(args.report)
    else:
        collect(args.log)
