# 本地打包说明

当前独立源码版本：1.6.5。项目不配置自动发布；没有预先承诺可下载的 GitHub 安装包。

先运行 `./test.sh`，再运行 `./scripts/package.sh`，默认构建 Apple Silicon 与 Intel 通用应用。脚本从应用 Info.plist 读取版本，输出 `dist/AgentBattery-1.6.5-macOS.zip` 与 `dist/SHA256SUMS.txt`。`--no-build` 仅用于已核对版本与架构的现有产物。

压缩包含应用、安装入口、许可证与文档。解压后运行 `一键安装.command`；遇到来源检查按 macOS 系统提示处理。采用 ad-hoc 签名，未做 Apple 公证。

发布前检查版本、架构、许可证、隐私、校验和及实际测试结果，不附带运行数据、凭据、个人设置或真实账户截图。离线夹具不是接口或当前余额验证，DeepSeek 今日花费始终是估算。
