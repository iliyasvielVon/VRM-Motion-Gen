# -*- coding: utf-8 -*-
"""多相机融合的自检：不用真相机，用合成视角逐条验证 rig.py 的每个承诺。

真值 = 自检正面.mocap.json 里的骨架序列。给每个「虚拟相机」一个已知旋转 + 各向异性
噪声（深度方向 5cm、图像平面 0.8cm——模拟单目「轮廓准、深度糊」的真实特性），然后断言：
标定能把已知旋转解回来、融合精度真的比单目好、中途加入要等标定完成、下线立刻移除、
镜像画面永远进不了融合。

    python tools/mocap/test_rig.py
"""

import json
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rig import CAL_FRAMES, VIEW_LOCAL, Rig, kabsch  # noqa: E402

FIX = Path(__file__).resolve().parent.parent.parent / "animations/mocap/自检正面.mocap.json"
TICK = 1.0 / 30.0

fails = 0


def ok(cond, what):
    global fails
    print("  %s  %s" % ("PASS" if cond else "FAIL", what))
    if not cond:
        fails += 1


def rot_y(deg):
    a = math.radians(deg)
    return np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])


def ang_deg(Ra, Rb):
    return math.degrees(math.acos(np.clip((np.trace(Ra @ Rb.T) - 1.0) / 2.0, -1.0, 1.0)))


def load_truth():
    data = json.loads(FIX.read_text(encoding="utf-8"))
    out = []
    for f in data["frames"]:
        if f.get("pose"):
            pts = np.array([p[:3] for p in f["pose"]])
            out.append(pts - pts.mean(axis=0))
    return out


def make_view(pts_ref, r_cam, rng, depth=0.05, plane=0.008):
    """这台相机看到的骨架：p_cam = R_camᵀ p_ref + 各向异性噪声（深度差、平面好）"""
    p = pts_ref @ r_cam
    d = VIEW_LOCAL
    n = rng.normal(size=p.shape) * plane
    n = n - np.outer(n @ d, d) * (1.0 - depth / plane)  # 深度方向换成大噪声
    p = p + n
    return {"pose": [[float(v[0]), float(v[1]), float(v[2]), 1.0] for v in p]}


def main():
    truth = load_truth()
    rng = np.random.default_rng(7)
    r_b = rot_y(75.0)
    events = []
    rig = Rig(on_event=events.append)
    t = 0.0

    print("[1. 单相机 = 参考相机，行为等同现在的单目]")
    for k in range(20):
        t += TICK
        rig.push("A", make_view(truth[k % len(truth)], np.eye(3), rng), t)
        fused, status = rig.fuse(t)
    ok(any("参考相机" in e for e in events), "第一台看到人的相机成为参考相机")
    ok(fused is not None and len(fused["pose"]) == 33 and len(fused["pose"][0]) == 4,
       "融合输出和单相机同一格式（33 点 × [x,y,z,vis]）")

    print("\n[2. 中途加入：第二台相机标定完成后才并入]")
    joined_at = -1
    for k in range(CAL_FRAMES + 30):
        t += TICK
        f_truth = truth[k % len(truth)]
        rig.push("A", make_view(f_truth, np.eye(3), rng), t)
        rig.push("B", make_view(f_truth, r_b, rng), t)
        fused, status = rig.fuse(t)
        st_b = next((e for e in status if e["id"] == "B"), None)
        if joined_at < 0 and st_b and st_b["st"] == "on":
            joined_at = k
    ok(joined_at >= CAL_FRAMES - 2, "B 攒满 %d 帧对应点才被启用（第 %d 帧启用）" % (CAL_FRAMES, joined_at))
    err = ang_deg(rig.cams["B"].R, r_b)
    ok(err < 3.0, "标定解出的旋转和真值差 %.2f°（相机实际摆在 75° 侧面）" % err)
    ok(any("标定完成" in e for e in events), "屏幕播报了「标定完成（残差 x cm）」")

    print("\n[3. 融合精度：侧面相机的图像平面补正面相机的深度]")
    # 每个姿势保持 5 tick、只在第 5 tick 采样：量的是空间融合精度。
    # 逐 tick 换姿势再逐 tick 采样会把输出滤波的 1~2 帧滞后也记成误差——
    # 滞后有自己的断言（第 7 节的突变追赶），别混在一起量。
    e_single, e_fused = [], []
    for k in range(180):
        t += TICK
        f_truth = truth[(k // 5) % len(truth)]
        va = make_view(f_truth, np.eye(3), rng)
        rig.push("A", va, t)
        rig.push("B", make_view(f_truth, r_b, rng), t)
        fused, _ = rig.fuse(t)
        if k % 5 != 4:
            continue
        fp = np.array([p[:3] for p in fused["pose"]])
        fp -= fp.mean(axis=0)
        ap = np.array([p[:3] for p in va["pose"]])
        ap -= ap.mean(axis=0)
        e_fused.append(np.linalg.norm(fp - f_truth, axis=1).mean())
        e_single.append(np.linalg.norm(ap - f_truth, axis=1).mean())
    es, ef = np.mean(e_single), np.mean(e_fused)
    ok(ef < es * 0.6, "融合误差 %.1f mm < 单目 %.1f mm 的 60%%（深度噪声被侧面相机压掉了）"
       % (ef * 1000, es * 1000))

    print("\n[4. 下线：断流即移除，剩下的相机继续]")
    t += 3.0                                   # B 断流 3 秒（> OFFLINE_S）
    rig.push("A", make_view(truth[0], np.eye(3), rng), t)
    fused, status = rig.fuse(t)
    ok(all(e["id"] != "B" for e in status), "B 断流后被直接移除")
    ok(any("下线" in e for e in events), "屏幕播报了下线")
    ok(fused is not None, "剩下的 A 继续正常出数据")

    print("\n[5. 镜像画面永远进不了融合（Kabsch 的 det 守门）]")
    mirror = np.diag([-1.0, 1.0, 1.0])
    for k in range(CAL_FRAMES * 3):
        t += TICK
        f_truth = truth[k % len(truth)]
        rig.push("A", make_view(f_truth, np.eye(3), rng), t)
        pm = f_truth @ mirror                  # 镜像过的骨架（左右反了）
        rig.push("C", {"pose": [[float(v[0]), float(v[1]), float(v[2]), 1.0] for v in pm]}, t)
        fused, status = rig.fuse(t)
    st_c = next((e for e in status if e["id"] == "C"), None)
    ok(st_c is not None and st_c["st"] != "on",
       "镜像相机 C 一直没被启用（det 判据直接识破反射）")
    ok(any("镜像" in e for e in events), "屏幕播报了「画面是镜像的，拒收」")

    print("\n[7. 稳定性：多目不许比单目更抖（用户实测抖动的三个来源，各钉一条）]")
    rig2 = Rig(on_event=lambda m: None)
    t2 = 1000.0
    static = truth[0]
    for k in range(CAL_FRAMES + 20):                 # 先把双机标定好
        t2 += TICK
        rig2.push("A", make_view(static, np.eye(3), rng), t2)
        rig2.push("B", make_view(static, r_b, rng), t2)
        rig2.fuse(t2)
    # 静止 + 满检测噪声 + B 只有 10fps（每 3 tick 一帧）：量输出的帧间跳动
    deltas = []
    prev = None
    for k in range(90):
        t2 += TICK
        rig2.push("A", make_view(static, np.eye(3), rng), t2)
        if k % 3 == 0:
            rig2.push("B", make_view(static, r_b, rng), t2)
        fused2, _ = rig2.fuse(t2)
        pts = np.array([p[:3] for p in fused2["pose"]])
        if prev is not None:
            deltas.append(float(np.linalg.norm(pts - prev, axis=1).mean()))
        prev = pts
    ok(float(np.mean(deltas)) < 0.006,
       "静止 + 双机不同帧率：帧间跳动 %.1f mm/tick（进门低通+年龄权重+One-Euro 三层一起压）"
       % (np.mean(deltas) * 1000))
    ok(float(np.max(deltas)) < 0.02,
       "慢相机更新/让位的瞬间没有猛跳（最大单帧 %.1f mm）" % (np.max(deltas) * 1000))
    # 快动作不拖影：姿势突变后 10 tick（1/3 秒）内要追上——One-Euro 速度越快放得越开
    target = truth[18]
    err = 1.0
    for k in range(10):
        t2 += TICK
        rig2.push("A", make_view(target, np.eye(3), rng), t2)
        rig2.push("B", make_view(target, r_b, rng), t2)
        fused2, _ = rig2.fuse(t2)
        pts = np.array([p[:3] for p in fused2["pose"]])
        pts -= pts.mean(axis=0)
        err = float(np.linalg.norm(pts - target, axis=1).mean())
    ok(err < 0.03, "姿势突变后 1/3 秒追到 %.0f mm 内（平滑没换来拖影）" % (err * 1000))

    print("\n[6. Kabsch 本身]")
    a = np.random.default_rng(1).normal(size=(50, 3))
    r_true = rot_y(38.0)
    r_est, rms = kabsch(a, a @ r_true.T)
    ok(ang_deg(r_est, r_true) < 1e-4 and rms < 1e-6,
       "无噪声时解出的旋转只剩浮点误差（%.1e°）" % ang_deg(r_est, r_true))

    print("\n结果：%s" % ("全部通过" if fails == 0 else "%d 项失败" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
