# TikTok 去水印下载插件源码

此仓库包含 Theos / Logos 插件源码。

## 本次修正

- 下载按钮不再只依赖外部 `download.png`；即使图标资源缺失，也会显示“去水印”文字按钮。
- 为按钮增加深色半透明背景、圆角和前置显示，减少透明按钮难以辨认的问题。
- 下载地址为空时给出提示并停止。
- 遇到 `.m3u8` 格式时提示不支持并立即返回，不再继续错误下载。

## 编译说明

使用 Theos 编译，入口文件为 `Makefile`。项目仍依赖外部 `libhdev` Framework，其中提供 `HDownloadMediaWithProgress` 和 `HCommon`。该依赖没有包含在本仓库中，必须先准备好对应 Framework 才能完成编译。

## 兼容性说明

按钮仍通过 `AWEPlayInteractionViewController` 的 `viewDidLoad` 挂载。是否能在 TikTok 47.6.0 中命中该控制器，必须结合目标 IPA 的运行时类结构或设备日志验证；本次只修复源码中已确认的按钮显示与下载分支问题，不宣称已验证 Hook 兼容性。

仓库中的现有 dylib 未由本次修改重新编译，不能把它当作本次修复后的二进制。
