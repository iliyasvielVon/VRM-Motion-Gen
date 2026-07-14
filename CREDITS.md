# 第三方素材与授权

本仓库**自己写的代码**（`scripts/`、`tools/`、`scenes/`）按 [MIT](LICENSE) 发布。
但仓库里还带着别人的东西，各有各的条款，用之前请看清楚——尤其是那个预览模型。

## ⚠️ 预览模型 `avatars/avatar0.vrm`

VRoid Studio 2.13.0 导出的模型，**作者：测试样例人**。它的 VRM meta 里写死了这些条款
（用 `godot --headless --path . --script res://tools/dump_meta.gd` 可以自己验一遍）：

| 条款 | 值 | 意思 |
|---|---|---|
| `allow_redistribution` | **Allow** | 可以跟着仓库分发（所以它在这儿） |
| `modification` | AllowModificationRedistribution | 可以改，改完也可以再分发 |
| `license_name` | **CC_BY** | **必须署名原作者** |
| `allowed_user_name` | Everyone | 谁都能用 |
| `commercial_usage_type` | **PersonalNonProfit** | **仅限个人非商用** |
| `violent_usage` | **Disallow** | 不得用于暴力表现 |
| `sexual_usage` | **Disallow** | 不得用于性表现 |

**要拿这个项目做商业用途，请先把 `avatars/avatar0.vrm` 换成你自己有权使用的模型**
（换模型只需改 `scripts/anim_studio.gd` 顶部的 `AVATAR` 常量）。工具本身（MIT）不限制商用，
受限的只是这个预览模型。

`animations/mocap/*.mocap.json` 和 `*.truth.json` 是自检用的关键点数据，由这个模型渲染出来的
视频跑出来的，跟着同样的条款。

## 插件

| 插件 | 授权 | 来源 |
|---|---|---|
| `addons/vrm` | MIT | [V-Sekai/godot-vrm](https://github.com/V-Sekai/godot-vrm) |
| `addons/Godot-MToon-Shader` | MIT | [V-Sekai/Godot-MToon-Shader](https://github.com/V-Sekai/Godot-MToon-Shader)，含 © 2018 Masataka SUMI |

## 动补

| 东西 | 授权 | 说明 |
|---|---|---|
| [MediaPipe](https://github.com/google-ai-edge/mediapipe) | Apache-2.0 | `pip install` 装 |
| `holistic_landmarker.task` 模型权重（13MB） | Apache-2.0（Google） | **不在仓库里**：`tools/mocap/capture.py` 首次运行会自己下 |
| [OpenCV](https://opencv.org/) | Apache-2.0 | `pip install` 装 |
| [aiohttp](https://github.com/aio-libs/aiohttp) | Apache-2.0 | 只有手机动补（`--phone`）用得上 |
| [cryptography](https://github.com/pyca/cryptography) | Apache-2.0 / BSD | 同上，用来现签局域网自签证书 |

## 引擎

Godot Engine 4.6（MIT）。本仓库不含引擎，自己去 [godotengine.org](https://godotengine.org/) 下。
