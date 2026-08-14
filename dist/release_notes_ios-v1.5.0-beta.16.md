# Aaalice NAI Launcher iOS 1.5.0 beta 16

- 修复砂糖云被强制切到 `/generate` 后只剩文生图、官方高级参数被丢弃的问题。
- 普通生成恢复走 `/novelai`，完整保留图生图、局部重绘、多角色与坐标、Precise Reference、预编码 Vibe 等 NovelAI 请求参数。
- 未编码的原始 Vibe 图片自动使用砂糖云 `/generate` 服务端编码通道，同时保留图生图、多角色、自定义尺寸和多图生成。
- 兼容 JSON、任务事件流、ZIP、直接图片与图片 URL/Base64 响应，并修复持续连接导致生成状态不结束的问题。
