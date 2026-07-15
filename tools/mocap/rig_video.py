# -*- coding: utf-8 -*-
"""离线多机位：几段「大概率同时录制」的视频 → 自动对时 → 标定 → 融合 → 关键点文件。

    python tools/mocap/capture.py --rig-video 正面.mp4,侧面.mp4 --out 圆舞

机位随便摆，摆完不动就行；几台设备不用同一瞬间按下录制。对时有两条路：

**自动对时（默认）**：动作本身就是时钟——每路视频逐帧过 MediaPipe 后取关节弯曲角
（肘/膝，左右排序对称化）做运动签名，30Hz 互相关找开录错位。对真人素材设计；
诚实的限制：在「动漫渲染 + 65° 侧视」的自检最坏样本上，侧机的姿态估计质量不足以
对时（被遮挡的半边身体是模型编的，和真实动作不相关）——所以自动对时是尽力而为，
结果和相关系数都会打印出来让你核对。

**手动对时（兜底，最稳）**：拍摄开头拍个手（打板），在每段视频里找到拍手那一帧的
时间，用 --sync-offsets 直接给（秒，和视频列表一一对应）：

    python tools/mocap/capture.py --rig-video a.mp4,b.mp4 --sync-offsets 0,1.27 --out 名字

对齐之后，标定和融合与实时 rig 完全共用同一份数学（rig.calibrate_pairs / Rig）。
离线还占个便宜：拿**整段重叠区间**的对应点一次标定，比实时流式的 45 帧稳得多；
标定不过关（残差 > CAL_RMS_OK）的机位整段弃用，绝不让它污染融合——
和实时「成功融合后再启用」同一条规矩。

产出 animations/mocap/<名>.mocap.json，回编辑器点「导入视频动补」即用。
"""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mediapipe as mp  # noqa: E402
from rig import (CAL_RMS_OK, Rig, _np_pose, calibrate_pairs,  # noqa: E402
                 make_pair)

FUSE_FPS = 30.0
SYNC_WINDOW_S = 10.0       # 开录错位的搜索窗（±秒）
MIN_OVERLAP = 30           # 互相关至少要这么多帧重叠才可信
MIN_CORR = 0.35            # 峰值相关系数低于它 = 两段视频对不上（不是同一段动作？）
MIN_PAIRS = 20             # 标定至少要的对应帧数


def _detect(path, make_landmarker, pack):
    """一路视频逐帧过 MediaPipe（各自独立的识别器实例）"""
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        sys.exit("打不开视频：%s" % path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    lm = make_landmarker()
    packs = []
    while True:
        ok, bgr = cap.read()
        if not ok:
            break
        r = lm.detect_for_video(
            mp.Image(image_format=mp.ImageFormat.SRGB,
                     data=cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)),
            int(len(packs) / fps * 1000))
        packs.append(pack(r))
        if len(packs) % 90 == 0:
            print("    %s：%d 帧…" % (Path(path).name, len(packs)), flush=True)
    cap.release()
    return packs, fps


def _resample(packs, fps):
    """重采样到 30Hz 公共时间轴（就近取源帧；各视频帧率可以不同）"""
    n = max(1, int(len(packs) / fps * FUSE_FPS))
    return [packs[min(len(packs) - 1, int(round(k / FUSE_FPS * fps)))] for k in range(n)]


## 对时签名的通道：左右肘弯、左右膝弯（每对按大小排序，见 _signature）
_SIG_JOINTS = [((11, 13, 15), (12, 14, 16)),   # 肘
               ((23, 25, 27), (24, 26, 28))]   # 膝


def _joint_angle(pts, a, b, c):
    u, v = pts[a] - pts[b], pts[c] - pts[b]
    d = max(float(np.linalg.norm(u) * np.linalg.norm(v)), 1e-9)
    return float(np.degrees(np.arccos(np.clip(u @ v / d, -1.0, 1.0))))


def _signature(packs30):
    """运动签名 = 逐帧的关节弯曲角（肘、膝），左右按大小排序成对称不变量。

    走过的弯路都记在这：① 第一版用「关节速度」——帧间位移和两台相机各自的检测
    抖动同量级，跨机位相关性实测 ≈0，废；② 关节角是 3D 旋转不变量（哪个机位测
    都该一样）且是姿态量不是差分量，抗抖动；③ 左右要排序对称化——侧视下左右
    偶尔认反，排序后翻转免疫。返回 (N, 4)，缺测为 NaN。"""
    sig = np.full((len(packs30), 2 * len(_SIG_JOINTS)), np.nan)
    for k, p in enumerate(packs30):
        if not p.get("pose"):
            continue
        pts, vis = _np_pose(p["pose"])
        for ji, (jl, jr) in enumerate(_SIG_JOINTS):
            if min(vis[list(jl)].min(), vis[list(jr)].min()) >= 0.5:
                pair = sorted([_joint_angle(pts, *jl), _joint_angle(pts, *jr)])
                sig[k, 2 * ji:2 * ji + 2] = pair
    return sig


def _align(sig_ref, sig, max_lag):
    """对时：逐窗归一化互相关（NCC），返回 (shift, 峰值相关系数)。
    shift 的含义：参考机位第 k 帧 ←→ 这台机位第 k + shift 帧。

    必须逐窗归一化（每个 lag 的重叠段各自减均值除方差），不能全局 z-score 完
    再点积：信号里有开录前的静止段和检测掉帧的零洞，全局统计被它们拽偏后，
    错误的 lag 能拿到比正确 lag 更高的分（第一版就这么翻的车）。"""
    best = (0, -1e9)
    n_ch = sig_ref.shape[1]
    for lag in range(-max_lag, max_lag + 1):
        lo = max(0, -lag)
        hi = min(len(sig_ref), len(sig) - lag)
        if hi - lo < MIN_OVERLAP:
            continue
        num = den_x = den_y = 0.0
        cnt = 0
        for ci in range(n_ch):                    # 多通道：各通道去均值后合并成总 NCC
            x = sig_ref[lo:hi, ci]
            y = sig[lo + lag:hi + lag, ci]
            m = ~(np.isnan(x) | np.isnan(y))
            if m.sum() < MIN_OVERLAP // 2:
                continue
            xv = x[m] - x[m].mean()
            yv = y[m] - y[m].mean()
            num += float((xv * yv).sum())
            den_x += float((xv * xv).sum())
            den_y += float((yv * yv).sum())
            cnt += int(m.sum())
        if cnt < MIN_OVERLAP:
            continue
        d = float(np.sqrt(den_x * den_y))
        if d < 1e-9:
            continue
        c = num / d
        if c > best[1]:
            best = (lag, c)
    return best


def run(paths, out_name, make_landmarker, pack, out_dir, sync_offsets=None):
    """整条离线管线。sync_offsets = 每段视频的开录时刻（秒，手动打板对时；
    None = 自动互相关）。返回报告 dict（自检脚本要断言它）。"""
    report = {"videos": [], "offsets": {}, "calib": {}, "frames": 0, "multi_ratio": 0.0}

    print("[1/4] 逐帧识别（每路视频各一套 MediaPipe）")
    streams = {}
    for i, path in enumerate(paths):
        cid = "v%d" % i
        packs, fps = _detect(path, make_landmarker, pack)
        p30 = _resample(packs, fps)
        hits = sum(1 for p in p30 if p.get("pose"))
        streams[cid] = p30
        report["videos"].append({"id": cid, "path": str(path), "fps": round(fps, 2),
                                 "frames30": len(p30), "hits": hits})
        print("  %s = %s：%.1f fps，30Hz 轴上 %d 帧，认出人 %d 帧"
              % (cid, Path(path).name, fps, len(p30), hits), flush=True)

    # 参考机位 = 认出人最多的那路（标定和对时都拿它当基准）
    ref_id = max(streams, key=lambda c: sum(1 for p in streams[c] if p.get("pose")))
    ids = ["v%d" % i for i in range(len(paths))]
    if sync_offsets is not None:
        # 手动打板：offsets[i] = 第 i 段视频里「同一时刻」出现的秒数（比如拍手那帧）
        print("\n[2/4] 手动对时（--sync-offsets）——参考机位 %s" % ref_id)
        base = sync_offsets[ids.index(ref_id)]
        shifts = {}
        for i, cid in enumerate(ids):
            shifts[cid] = int(round((sync_offsets[i] - base) * FUSE_FPS))
            report["offsets"][cid] = {"shift": shifts[cid], "corr": 1.0, "manual": True}
            print("  %s 错位 %+d 帧（%+.2f 秒，手动指定）"
                  % (cid, shifts[cid], shifts[cid] / FUSE_FPS), flush=True)
    else:
        print("\n[2/4] 自动对时（动作互相关，搜索窗 ±%.0f 秒）——参考机位 %s"
              % (SYNC_WINDOW_S, ref_id))
        print("  【提示】自动对时是尽力而为；最稳的做法是开拍时拍个手，"
              "用 --sync-offsets 手动指定（见文件头）", flush=True)
        sig_ref = _signature(streams[ref_id])
        max_lag = int(SYNC_WINDOW_S * FUSE_FPS)
        shifts = {ref_id: 0}
        for cid, p30 in streams.items():
            if cid == ref_id:
                continue
            shift, corr = _align(sig_ref, _signature(p30), max_lag)
            shifts[cid] = shift
            report["offsets"][cid] = {"shift": shift, "corr": round(corr, 3)}
            # 别在提示里用 emoji/特殊符号：Windows 的 GBK 控制台会直接 UnicodeEncodeError
            note = "" if corr >= MIN_CORR else "  【注意】相关性太弱——确定这几段拍的是同一段动作？"
            print("  %s 错位 %+d 帧（%+.2f 秒），相关系数 %.2f%s"
                  % (cid, shift, shift / FUSE_FPS, corr, note), flush=True)
            if corr < MIN_CORR:
                print("  → %s 弃用（对不上时；用 --sync-offsets 手动指定可救）" % cid, flush=True)
                shifts.pop(cid)

    print("\n[3/4] 标定（整段重叠区间的对应点，一次修剪 Kabsch）")
    rig = Rig(on_event=lambda m: print("  " + m, flush=True), live=False)
    rig.preset_cam(ref_id, np.eye(3), is_ref=True)
    enabled = [ref_id]
    ref30 = streams[ref_id]
    for cid in list(shifts):
        if cid == ref_id:
            continue
        pairs = []
        for k, pref in enumerate(ref30):
            j = k + shifts[cid]
            if not (0 <= j < len(streams[cid])):
                continue
            pcam = streams[cid][j]
            if not (pref.get("pose") and pcam.get("pose")):
                continue
            f_pts, f_vis = _np_pose(pref["pose"])
            pair = make_pair(pcam["pose"], f_pts, f_vis)
            if pair is not None:
                pairs.append(pair)
        if len(pairs) < MIN_PAIRS:
            print("  %s 重叠可用帧只有 %d（< %d），弃用" % (cid, len(pairs), MIN_PAIRS), flush=True)
            continue
        R, rms, mirrored = calibrate_pairs(pairs)
        report["calib"][cid] = {"rms": round(rms, 3), "pairs": len(pairs),
                                "mirrored": mirrored}
        if mirrored:
            print("  %s 的画面是镜像的（左右翻转），整段弃用——"
                  "重新导出一份没镜像的再来" % cid, flush=True)
            continue
        if rms <= CAL_RMS_OK:
            rig.preset_cam(cid, R, rms=rms)
            enabled.append(cid)
            print("  %s 标定完成（%d 帧对应点，残差 %.1f cm），并入融合"
                  % (cid, len(pairs), rms * 100), flush=True)
        else:
            print("  %s 标定不过关（残差 %.1f cm > %.0f cm），整段弃用——"
                  "检查是不是镜像过/不是同一个人" % (cid, rms * 100, CAL_RMS_OK * 100), flush=True)

    print("\n[4/4] 融合（与实时同一份各向异性加权）")
    fused_frames = []
    multi = 0
    for k in range(len(ref30)):
        t = k / FUSE_FPS
        pushed = 0
        for cid in enabled:
            j = k + shifts.get(cid, 0)
            if 0 <= j < len(streams[cid]) and streams[cid][j].get("pose"):
                rig.push(cid, streams[cid][j], t=t)
                pushed += 1
        fused, _ = rig.fuse(now=t)
        if fused is not None and fused.get("pose"):
            fused_frames.append(fused)
            if pushed >= 2:
                multi += 1

    report["frames"] = len(fused_frames)
    report["multi_ratio"] = round(multi / max(1, len(fused_frames)), 3)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / ("%s.mocap.json" % out_name)
    out_path.write_text(json.dumps({
        "fps": FUSE_FPS,
        "source": "rig-video: " + ", ".join(Path(p).name for p in paths),
        "frames": fused_frames,
    }, ensure_ascii=False), encoding="utf-8")
    print("\n写出 %s（%d 帧，其中 %.0f%% 由多机位融合）——回编辑器点「导入视频动补」"
          % (out_path, len(fused_frames), report["multi_ratio"] * 100), flush=True)
    return report
