# Agent 流量管家

macOS 菜单栏中的 AI 账户额度与余额工具，使用 Swift / AppKit，支持 macOS 14 及以上。

本项目派生自 [Carolyn-ai/codex-battery](https://github.com/Carolyn-ai/codex-battery)，保留上游 Ling Talk AI 的 MIT 许可证及署名。在上游 Codex 工具基础上加入 Claude 官方订阅、B.AI、DeepSeek 与安全密钥输入等功能。当前源码版本为 **1.6.5**；这是独立源码项目，安装包发布由维护者另行安排。

## 从源码构建与安装

需要 Apple Command Line Tools（`xcode-select --install`）、Python 3 和 macOS 14+。各数据源需要你自己的登录或密钥；可只使用已配置的来源。私有仓库需要具有访问权限的 GitHub 账号。

```sh
git clone https://github.com/xuefei016/agent-traffic-manager.git
cd agent-traffic-manager
./test.sh
./build.sh
./install.sh --dry-run
./install.sh
```

`test.sh` 已包含本机架构构建、离线回归和 AppKit 自测；单独运行 `build.sh` 可重新构建。先构建，再安装。产物位于 `dist/Agent 流量管家.app`。源码 ZIP 解压后也可按上述顺序操作；`一键安装.command` 是安装入口。

安装器检查 bundle 身份和主版本，同主版本更新前备份应用与设置，遇到多个旧副本或无关应用会停止。沿用 `local.codex-battery` 身份与原设置目录，因此它会被识别为上游的同一应用，不能视为可并行安装的另一个实例。安装后默认不显示说明弹窗，再次打开应用会展开菜单。**首次正常启动会配置登录时启动**，可在菜单关闭。

构建使用本地 ad-hoc 签名，未做 Apple 公证。macOS 可能阻止打开；确认源码与来源后按系统“隐私与安全性”提示处理，不要关闭系统安全保护。

## 当前功能

- **文字菜单栏**：依次显示 Codex、Claude 或 B.AI、DeepSeek，可按菜单设置隐藏部分来源。
- **Codex 与 Claude 官方订阅**：统一选择 5 小时或每周周期，默认 5 小时。缺少所选周期时实现会回落到可用周期，菜单详情标出实际显示项；应结合实际时长判断，不把回落值当成所选周期。
- **Claude 第三方 B.AI**：显示 Credits，不是美元，也不受订阅周期开关影响。百万以上优先用 M，低于 100M 保留两位小数，100M 至不足 1000M 保留一位，再大取整；不足百万使用 K 或原值。菜单详情和 `status.json` 的 `baiBalanceCredits` 保留精确积分。个人余额、团队管理员余额、成员剩余配额分别解析；无限配额成员不伪造团队余额。
- **安全输入 B.AI 密钥**：遮罩输入框支持 ⌘V 和“从剪贴板粘贴”，保存到系统 Keychain。已有配置只接受与 HTTPS `api.b.ai` 明确配对的密钥。
- **DeepSeek**：显示官方余额接口返回的金额，以及本机余额差分得到的“今日花费估算”。没有从账单接口获取实际消费。
- **Codex 周期倒计时、公开重置消息、个人保留线与便签、时区设置、隔离演示**：公开消息与本人账户额度分开，不把公告当成账号到账证明。

常规刷新间隔为 Codex 60 秒、Claude/B.AI 5 分钟、DeepSeek 10 分钟；菜单打开、唤醒和会话激活也触发刷新，失败、在途请求及退避会影响实际执行。公共消息单独刷新。离线、限流或缺少凭证时应结合错误和更新时间判断，旧读数不代表当前余额。

## DeepSeek 估算边界

按系统本地时区划分日期，以当天首次成功采样建立基准。首次采样之前的消费、休眠或跨天未采样期间的消费可能漏算。余额上涨按净增加量平移基准；同一采样间隔内充值与消费只留下净变化，无法准确拆分，也不能把上涨值当成精确充值额。更频繁采样只能减少误差，不能恢复丢失的信息。

菜单“校准今日已花费…”或 `--set-deepseek-spent <金额>` 可调整估算；输入金额必须对应同一时刻的余额。校准后的变化仍是估算，不保证第二天或充值后与官网完全一致。

## 凭据、权限与数据

Codex 使用本机已登录的 `codex app-server` 只读查询。Claude 官方订阅读取 Claude Code 的 Keychain OAuth 登录，必要时回退至 `~/.claude/.credentials.json`；系统可能请求钥匙串访问授权。B.AI 的自有密钥保存在本工具专属 Keychain 项。DeepSeek 从 `~/.hermes/.env`、进程环境或 Hermes 配置读取已有密钥，目前没有独立的 DeepSeek 密钥录入入口。

程序需要网络、这些指定配置的读取权限、保存自身偏好/缓存与可选启动项的权限。它未使用 App Sandbox；不需要授予辅助功能、屏幕录制或完全磁盘访问权限来查询额度。没有遥测或作者接收端；供应商及公开消息网站仍可获得常规网络连接信息。详见 [隐私说明](PRIVACY.md) 与 [使用说明](docs/使用说明.md)。不要公开运行状态、密钥、配置和备份。

## 开发与验证

```sh
./test.sh
python3 scripts/privacy_check.py
./build.sh --universal
./scripts/package.sh
```

`test.sh` 直接传播失败退出码，测试使用合成夹具和隔离偏好，不查询真实账户；安装测试只使用临时目标，不启动或替换日常应用。自测中的数字不是当前账户余额。`package.sh` 默认构建 Apple Silicon / Intel 通用包，按应用版本命名；`--no-build` 仅打包现有产物，不保证其架构。

GitHub Actions 仅保留 macOS 源码检查与测试，不自动提交、推送或发布。MIT 许可见 [LICENSE](LICENSE)。本项目与 OpenAI、Anthropic、B.AI、DeepSeek 无隶属关系，服务协议或接口变更可能影响可用性。
