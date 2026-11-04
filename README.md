# TikTok 去水印下载插件源码

此仓库包含 Theos / Logos 插件源码，目标是给 TikTok 视频播放界面增加下载入口，并将下载的视频保存到系统照片图库。

## 本次修正

- 下载按钮显示中文“去水印”，不再依赖外部 PNG 图标才能看见按钮。
- 增加本地下载与 Photos 保存实现，移除原先缺失的 `libhdev` Framework 依赖。
- 下载地址无效、下载失败或照片权限不足时给出提示。
- 对 `.m3u8` / `.mpd` 分段流媒体地址明确提示暂不支持，避免将流媒体清单误存为 MP4。
- 新增 GitHub Actions Theos 构建流程，编译产物作为 Actions Artifact 提供。

## 编译与验证状态

推送源码不等于已经成功编译。请查看仓库 Actions 中最新的 **Build TikTokNoWatermark dylib** 工作流；只有工作流成功且 Artifact 中存在 `TikTokNoWatermark.dylib`，才算完成编译。

## 重要限制

- “去水印”按钮目前下载 TikTok 模型提供的 `downloadURL`（若没有则回退到 `playURL`）地址。TikTok 是否向当前账号/视频返回无水印源地址，必须在真实视频上验证；源码不能保证所有视频都无水印。
- Hook 仍使用 `AWEPlayInteractionViewController`。是否命中 TikTok 47.6.0，必须在该版本 IPA/设备上运行验证。
- 本仓库不包含已验证可注入的 IPA，也不代表 Scarlet、ESign 或 Feather 已完成注入和签名验证。
