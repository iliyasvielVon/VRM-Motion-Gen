"""多相机融合（rig）：几台普通摄像头/手机拼成一套「多目动补」。

不需要棋盘格——**人本身就是标定板**：MediaPipe 给每台相机各出一副「以胯为原点、
朝向跟着相机走」的公制 3D 骨架。同一时刻两台相机看到的是同一副骨架，只差一个
刚体旋转。攒够 CAL_FRAMES 帧对应点，修剪 Kabsch(SVD) 解出「该相机 → 参考坐标系」
的旋转，残差达标才允许进融合（对应需求：成功融合后再启用）。

诚实的限制（test_rig_real.py 用两个已知夹角的真实机位量出来的）：MediaPipe 对
侧视的人有系统性「转正」偏置（65° 机位解出约 41°），所以标定出的是**两台相机
自洽的对齐**，不是精确的物理角度。对本用途够用——下游只用方向向量驱骨骼，且
多相机最大的收益本来就在「可见度互补」（哪台看得清腿就听哪台的），那不依赖
精确角度。想要测绘级角度得上棋盘格+三角化，不在本工具的射程里。

融合是**各向异性加权**：单目的软肋在深度（沿视线方向的误差约是图像平面的两倍，
见 test_mocap 实测 12.7° / 27.6°）。所以每台相机沿自己视线方向的话语权打 W_DEPTH
折，图像平面方向全额——侧面相机的图像平面恰好补正面相机的深度，这就是多目的意义。

生命周期（逐条对应需求）：
  · 第一台看到人的相机 = 参考相机，定义世界坐标系，立即启用；
  · 之后加入的相机（含中途连上的手机）先「标定中」：攒对应点 → 解旋转 →
    残差 ≤ CAL_RMS_OK 才启用，不达标就扔掉一半继续攒；
  · 断流 OFFLINE_S 秒（或 WebSocket 断开）→ 直接移除，剩下的相机继续；
  · 已启用相机的残差持续超标 = 相机八成被挪动了 → 自动退回「标定中」重标；
    多台同时超标则更像参考相机被挪了，只播报建议重启，不搞连坐。

纯逻辑、无 I/O、时间可注入——test_rig.py 用合成视角逐条断言上面每一句话。
"""

import threading
import time
from collections import deque

import numpy as np

POSE_N = 33
NOSE, WRIST_L, WRIST_R = 0, 15, 16

VIS_CAL = 0.6         # 标定只用两边都看得清的关节
MIN_CAL_JOINTS = 8
CAL_FRAMES = 45       # 攒这么多帧对应点才解一次（30fps 下约 1.5 秒）
## 米。修剪后的 Kabsch 残差超过它 = 两台相机拼不上，不许进融合。
## 阈值不是拍脑袋：真实双机（65° 夹角、动漫渲染最难样本）修剪后 9.0cm，
## 镜像画面 11.3cm——0.10 正好放行前者、拒掉后者（test_rig_real.py 量的）。
CAL_RMS_OK = 0.10
CAL_TRIM = 0.7        # 修剪 Kabsch：按逐帧残差留最好的 70% 重解（丢掉检测抽风的帧）
FRESH_S = 0.35        # 数据比这旧就不进本轮融合（没有硬件同步，靠新鲜度对齐）
OFFLINE_S = 2.5       # 比这旧直接判下线移除
W_DEPTH = 0.2         # 深度方向的话语权（图像平面 = 1.0）
RECAL_RMS = 0.14      # 已融合相机的滚动残差中位数超过它 → 判定被挪动，重标
RECAL_WIN = 60
VIEW_LOCAL = np.array([0.0, 0.0, -1.0])   # 相机在自己坐标系里的视线方向


def _np_pose(pose):
    pts = np.zeros((POSE_N, 3))
    vis = np.zeros(POSE_N)
    for i, p in enumerate(pose):
        pts[i] = p[:3]
        vis[i] = p[3] if len(p) > 3 else 1.0
    return pts, vis


def kabsch(A, B):
    """使 R @ A[i] ≈ B[i] 的最小二乘旋转（A、B 都已各自去质心），返回 (R, rms)。
    det 修正保证解出来的是纯旋转——镜像过的画面（反射）拟合不出来，残差会爆表，
    这正好当成「这台相机的画面被镜像了/根本不是同一个人」的守门员。"""
    H = A.T @ B
    U, _, Vt = np.linalg.svd(H)
    d = np.sign(np.linalg.det(Vt.T @ U.T))
    R = Vt.T @ np.diag([1.0, 1.0, d]) @ U.T
    rms = float(np.sqrt(np.mean(np.sum((A @ R.T - B) ** 2, axis=1))))
    return R, rms


class Cam:
    def __init__(self, cam_id):
        self.id = cam_id
        self.state = "wait"            # wait（等人入镜）→ calib（标定中）→ on（已融合）
        self.is_ref = False
        self.R = None                  # 本相机 → 参考坐标系的旋转
        self.rms = None
        self.frame = None              # 最近一帧原始关键点 dict
        self.t = 0.0
        self.buf = deque(maxlen=120)   # 标定对应点 [(A_centered, B_centered), ...]
        self.resid = deque(maxlen=RECAL_WIN)


class Rig:
    def __init__(self, on_event=None):
        self._lock = threading.Lock()
        self.cams = {}
        self._event = on_event or (lambda msg: None)

    # ---------------------------------------------------------------- 输入

    def push(self, cam_id, frame, t=None):
        """任何线程随时喂一帧（相机线程 / 手机 WebSocket 都走这儿）"""
        with self._lock:
            cam = self.cams.get(cam_id)
            if cam is None:
                cam = self.cams[cam_id] = Cam(cam_id)
                self._event("相机 %s 接入，等待画面里出现人" % cam_id)
            cam.frame = frame
            cam.t = time.monotonic() if t is None else t

    def offline(self, cam_id, reason="断开"):
        with self._lock:
            self._drop(cam_id, reason)

    def _drop(self, cam_id, reason):
        cam = self.cams.pop(cam_id, None)
        if cam is not None:
            self._event("相机 %s 下线（%s）%s" % (cam_id, reason,
                "——它是参考相机，但坐标系已经立住了，其余相机继续" if cam.is_ref else ""))

    # ---------------------------------------------------------------- 融合

    def fuse(self, now=None):
        """跑一轮融合，返回 (融合后的一帧 或 None, 状态列表)"""
        with self._lock:
            return self._fuse(time.monotonic() if now is None else now)

    def _fuse(self, now):
        for cid in [c for c in list(self.cams) if now - self.cams[c].t > OFFLINE_S]:
            self._drop(cid, "%.0f 秒没数据" % OFFLINE_S)

        fresh = [c for c in self.cams.values()
                 if now - c.t < FRESH_S and c.frame and c.frame.get("pose")]

        # 第一台看到人的相机 = 参考相机：它的坐标系就是世界坐标系
        if not any(c.state == "on" for c in self.cams.values()):
            for cam in fresh:
                cam.state = "on"
                cam.is_ref = True
                cam.R = np.eye(3)
                self._event("相机 %s 成为参考相机（定义坐标系），已启用" % cam.id)
                break

        on = [c for c in fresh if c.state == "on"]
        fused = self._fuse_pose(on) if on else None

        if fused is not None:
            f_pts, f_vis = fused
            for cam in fresh:
                if cam.state == "on":
                    continue
                if cam.state == "wait":
                    cam.state = "calib"
                    self._event("相机 %s 看到人了，开始标定——请站到两台相机都拍得到的位置动一动"
                                % cam.id)
                self._collect(cam, f_pts, f_vis)
            self._watch_moved(on, fused)

        return self._pack(fused, on), self._status()

    ## 各向异性加权融合：每台相机沿自己视线方向（深度）只有 W_DEPTH 的话语权
    def _fuse_pose(self, on):
        pts = np.zeros((POSE_N, 3))
        vis = np.zeros(POSE_N)
        M = np.zeros((POSE_N, 3, 3))
        b = np.zeros((POSE_N, 3))
        for cam in on:
            a_pts, a_vis = _np_pose(cam.frame["pose"])
            P = a_pts @ cam.R.T                       # 旋进参考坐标系
            d = cam.R @ VIEW_LOCAL
            W = (np.eye(3) - np.outer(d, d)) + W_DEPTH * np.outer(d, d)
            for j in range(POSE_N):
                w = a_vis[j]
                if w < 0.15:
                    continue                          # 这台相机看不清的关节不投票
                M[j] += w * W
                b[j] += w * (W @ P[j])
                vis[j] = max(vis[j], a_vis[j])        # 任何一台看得清就算看得清
        for j in range(POSE_N):
            if vis[j] > 0.0:
                pts[j] = np.linalg.solve(M[j], b[j])
        return pts, vis

    ## 标定：攒（本相机骨架, 融合骨架）对应点，够数就 Kabsch，残差达标才启用
    def _collect(self, cam, f_pts, f_vis):
        a_pts, a_vis = _np_pose(cam.frame["pose"])
        idx = np.where((a_vis >= VIS_CAL) & (f_vis >= VIS_CAL))[0]
        if len(idx) < MIN_CAL_JOINTS:
            return
        A = a_pts[idx] - a_pts[idx].mean(axis=0)      # 逐帧各自去质心：只解旋转
        B = f_pts[idx] - f_pts[idx].mean(axis=0)
        cam.buf.append((A, B))
        if len(cam.buf) < CAL_FRAMES:
            return
        # 修剪 Kabsch：先全量解一次，按逐帧残差扔掉最差的 30%（检测抽风/遮挡帧），再重解
        R0, _ = kabsch(np.vstack([p[0] for p in cam.buf]),
                       np.vstack([p[1] for p in cam.buf]))
        per = [float(np.sqrt(np.mean(np.sum((a @ R0.T - b) ** 2, axis=1))))
               for a, b in cam.buf]
        keep = sorted(range(len(cam.buf)), key=lambda i: per[i])
        keep = keep[:max(3, int(len(cam.buf) * CAL_TRIM))]
        R, rms = kabsch(np.vstack([cam.buf[i][0] for i in keep]),
                        np.vstack([cam.buf[i][1] for i in keep]))
        if rms <= CAL_RMS_OK:
            cam.R = R
            cam.rms = rms
            cam.state = "on"
            cam.buf.clear()
            cam.resid.clear()
            self._event("相机 %s 标定完成（残差 %.1f cm），已并入融合" % (cam.id, rms * 100))
        else:
            for _ in range(len(cam.buf) // 2):        # 扔掉旧的一半，继续攒
                cam.buf.popleft()
            self._event("相机 %s 标定未收敛（残差 %.1f cm > %.0f cm），继续采集——"
                        "检查画面是否被镜像、是不是同一个人" % (cam.id, rms * 100, CAL_RMS_OK * 100))

    ## 相机被挪动的看门狗：已启用相机的滚动残差持续超标 → 退回重标。
    ## 多台同时超标更像是参考相机被挪了——只播报，不搞连坐。
    def _watch_moved(self, on, fused):
        if len(on) < 2:
            return
        f_pts, f_vis = fused
        flagged = []
        non_ref = [c for c in on if not c.is_ref]
        for cam in non_ref:
            a_pts, a_vis = _np_pose(cam.frame["pose"])
            idx = np.where((a_vis >= VIS_CAL) & (f_vis >= VIS_CAL))[0]
            if len(idx) < MIN_CAL_JOINTS:
                continue
            A = a_pts[idx] - a_pts[idx].mean(axis=0)
            B = f_pts[idx] - f_pts[idx].mean(axis=0)
            cam.resid.append(float(np.sqrt(np.mean(np.sum((A @ cam.R.T - B) ** 2, axis=1)))))
            if len(cam.resid) >= RECAL_WIN and float(np.median(cam.resid)) > RECAL_RMS:
                flagged.append(cam)
        if flagged and len(non_ref) >= 2 and len(flagged) > len(non_ref) // 2:
            self._event("多台相机残差同时飙高——更像是参考相机被挪动了，建议重启重新标定")
            for cam in on:
                cam.resid.clear()
            return
        for cam in flagged:
            cam.state = "calib"
            cam.R = None
            cam.rms = None
            cam.buf.clear()
            cam.resid.clear()
            self._event("相机 %s 残差持续超标（像是被挪动了），退回重新标定" % cam.id)

    # ---------------------------------------------------------------- 输出

    def _pack(self, fused, on):
        if fused is None:
            return None
        f_pts, f_vis = fused
        pose = [[round(float(p[0]), 4), round(float(p[1]), 4), round(float(p[2]), 4),
                 round(float(v), 3)] for p, v in zip(f_pts, f_vis)]
        return {"pose": pose,
                "lh": self._pick_hand(on, "lh", WRIST_L),
                "rh": self._pick_hand(on, "rh", WRIST_R),
                "bs": self._pick_bs(on)}

    ## 手不做平均：侧后方相机可能把左右手认反，平均只会掺垃圾。
    ## 每只手挑「腕部看得最清」的那台相机，整只用它的（旋进参考坐标系）。
    def _pick_hand(self, on, key, wrist_idx):
        best, best_vis = None, 0.0
        for cam in on:
            hand = cam.frame.get(key)
            if not hand:
                continue
            _, a_vis = _np_pose(cam.frame["pose"])
            if a_vis[wrist_idx] > best_vis:
                best_vis, best = a_vis[wrist_idx], (cam, hand)
        if best is None:
            return None
        cam, hand = best
        H = np.array([p[:3] for p in hand]) @ cam.R.T
        return [[round(float(x), 4) for x in p] for p in H]

    ## 表情挑「鼻尖看得最清」的那台相机（= 最正对脸的那台）
    def _pick_bs(self, on):
        best, best_vis = None, 0.0
        for cam in on:
            if cam.frame.get("bs"):
                _, a_vis = _np_pose(cam.frame["pose"])
                if a_vis[NOSE] > best_vis:
                    best_vis, best = a_vis[NOSE], cam.frame["bs"]
        return best

    def _status(self):
        out = []
        for cam in self.cams.values():
            e = {"id": cam.id, "st": cam.state, "ref": cam.is_ref}
            if cam.state == "on" and cam.rms is not None:
                e["rms"] = round(cam.rms, 3)
            if cam.state == "calib":
                e["prog"] = round(min(1.0, len(cam.buf) / float(CAL_FRAMES)), 2)
            out.append(e)
        return out

    def status(self):
        with self._lock:
            return self._status()
