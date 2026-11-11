# diubangwenjian

局域网 P2P 互传 / NAS 浏览（Flutter）。

## 架构注意事项

开发涉及对端连接、设备列表导航、WS 状态时，请先读：

- [docs/architecture_notes.md](docs/architecture_notes.md) — **对端 WS 显式 leave**、易遗漏断连的检查清单
- [docs/聊天互传路线综合策略.md](docs/聊天互传路线综合策略.md) — 聊天/NAS 落地、收包对称、预览缓存
- [docs/peer_device_model_and_status_plan.md](docs/peer_device_model_and_status_plan.md) — 伙伴模型与 `peer.status`

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
