# Aaalice NAI Launcher iOS 1.5.0 beta 20

- 修复超分提示完成，但本地画廊新增“加载失败”图片的问题。
- 经在线验证，砂糖云缺失的 `/ai/upscale` 会以 HTTP 200 返回 `{"error":"File not found"}`；旧版误把该 JSON 当作 PNG 保存。
- 砂糖云账号下不再开放不可用的 NovelAI 云端超分按钮，并会明确提示切换官方 NovelAI 账号或使用 ComfyUI。
- 超分响应及其他外部工作流结果写入历史和图库前，必须通过真实图片格式校验，错误 JSON 不会再产生损坏记录。
- 官方 NovelAI 返回的 ZIP 超分图片和直接图片响应继续正常支持。
