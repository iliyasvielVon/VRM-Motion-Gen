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
import rig as rig_mod  # noqa: E402
from rig import CAL_FRAMES, VIEW_LOCAL, Rig, is_mirrored, kabsch  # noqa: E402

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

    print("\n[8. 实测回归（真机日志里抓到的三个问题，各钉一条）]")
    # 8a 摇头要传出去：头的朝向藏在鼻/耳的小三角形里，两台带标定偏差的相机逐点平均
    # 会把它抹掉（真机实测：用户摇头，模型纹丝不动）。修法 = 脸单源直取。
    rig3 = Rig(on_event=lambda m: None)
    rig3.preset_cam("A", np.eye(3), is_ref=True)
    rig3.preset_cam("B", rot_y(75.0 - 8.0), rms=0.05)   # B 的标定故意差 8°（模拟转正偏置）
    t3 = 2000.0

    def head_yaw(pts):
        fwd = pts[0] - (pts[7] + pts[8]) / 2.0          # 鼻尖 - 双耳中点
        return math.degrees(math.atan2(-fwd[2], fwd[0]))

    outs, tru = [], []
    for k in range(80):
        t3 += TICK
        yaw = 25.0 * math.sin(k / 10.0)
        c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        rh = np.array([[c, 0, s_], [0, 1, 0], [-s_, 0, c]])
        tr = truth[0].copy()
        head_c = tr[:11].mean(axis=0)
        tr[:11] = (tr[:11] - head_c) @ rh.T + head_c    # 只转头
        rig3.push("A", make_view(tr, np.eye(3), rng, depth=0.012, plane=0.005), t3)
        rig3.push("B", make_view(tr, rot_y(75.0), rng, depth=0.012, plane=0.005), t3)
        fused3, _ = rig3.fuse(t3)
        if k > 15:
            pts = np.array([q[:3] for q in fused3["pose"]])
            outs.append(head_yaw(pts))
            tru.append(head_yaw(tr))
    corr = float(np.corrcoef(outs, tru)[0, 1])
    amp = float(np.std(outs) / max(np.std(tru), 1e-9))
    ok(corr > 0.85 and 0.55 < amp < 1.4,
       "摇头 ±25°（B 标定带 8° 偏差）：输出头朝向相关 %.2f、幅度保持 %.0f%%——脸单源没被平均抹掉"
       % (corr, amp * 100))

    # 8b 时间错位的运动补偿：B 永远比 A 慢一拍（10fps + 内容滞后），转身时
    # 不外推的话融合被旧姿势往回拽出「鬼影」。同一份数据开/关补偿各跑一遍对比。
    def run_skew(comp):
        rig_mod.VEL_COMP_MAX = 0.15 if comp else 0.0
        r4 = Rig(on_event=lambda m: None)
        r4.preset_cam("A", np.eye(3), is_ref=True)
        r4.preset_cam("B", rot_y(75.0), rms=0.03)
        rng4 = np.random.default_rng(21)
        t4 = 3000.0
        errs = []
        for k in range(60):
            t4 += TICK
            spin = rot_y(4.0 * k)                        # 整个人 120°/s 匀速转身
            tr = truth[0] @ spin.T
            r4.push("A", make_view(tr, np.eye(3), rng4), t4)
            if k % 3 == 0:                               # B 只有 10fps，天然比 A 旧
                r4.push("B", make_view(tr, rot_y(75.0), rng4), t4)
            fused4, _ = r4.fuse(t4)
            if k > 15:
                pts = np.array([q[:3] for q in fused4["pose"]])
                pts -= pts.mean(axis=0)
                errs.append(float(np.linalg.norm(pts - tr, axis=1).mean()))
        return float(np.mean(errs))

    e_on = run_skew(True)
    e_off = run_skew(False)
    rig_mod.VEL_COMP_MAX = 0.15
    # 差值看着不大是因为两边都背着同一份 One-Euro 稳态滞后（~30mm 基线），
    # 补偿消的是「慢机拖影」那一份——方向和量级都要对
    ok(e_on < e_off - 0.002,
       "转身 120°/s + 慢机滞后：开运动补偿误差 %.1f mm < 不补 %.1f mm——慢机拖影被外推抵掉"
       % (e_on * 1000, e_off * 1000))

    # 8c 镜像判据不误杀：真机上遮挡期的退化数据曾让 det 翻负、误杀了没镜像的手机
    rng8 = np.random.default_rng(11)
    garbage_a = rng8.normal(size=(200, 3))
    garbage_b = rng8.normal(size=(200, 3))               # 完全不相关：det 一半概率翻负
    ok(not is_mirrored(garbage_a, garbage_b),
       "不相关的垃圾数据不再被误判成镜像（反射拟合没有明显优势，边际条件挡住）")
    ok(is_mirrored(garbage_a * np.array([-1.0, 1.0, 1.0]), garbage_a),
       "真正的点云反射照旧一抓一个准")

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
