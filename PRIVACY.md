# 隐私与数据说明

仓库仅含通用源码、合成离线测试、文档及构建脚本，不附带真实余额、账户记录、截图、登录资料或运行状态。MIT 上游署名保留于 LICENSE。

## 运行时访问

- **Codex**：启动本机 `codex app-server --stdio`，执行初始化及 `account/rateLimits/read`。不读取 Codex 登录文件，不创建聊天或调用模型；Codex 自己管理认证。
- **Claude 官方订阅**：通过系统 `security` 工具读取 `Claude Code-credentials` Keychain 项，必要时读取 `~/.claude/.credentials.json` 中 OAuth access token 与过期时间。令牌用于 `https://api.anthropic.com/api/oauth/usage` 只读查询，不在状态文件中输出。系统可能提示授权；登录过期需在 Claude Code 自行刷新。
- **B.AI**：密钥优先来自本工具 Keychain（服务 `local.codex-battery.bai`、账号 `api.b.ai`），再从进程环境或 `~/.claude/settings.local.json`、`settings.json` 中读取；后两者仅接受与同一配置中 HTTPS `api.b.ai` 明确配对的密钥。只读请求固定 `https://api.b.ai/v1/balance`，拒绝重定向，错误为固定脱敏文本。安全输入支持 ⌘V 与可见粘贴按钮，粘贴会读取剪贴板；程序不会自动清空剪贴板。
- **DeepSeek**：依次从 `~/.hermes/.env`、环境变量 `DEEPSEEK_API_KEY`、`~/.hermes/config.yaml` 中匹配的配置读取密钥。向 `https://api.deepseek.com/user/balance` 查询余额，不发推理请求。当前版本没有 DeepSeek 专用 Keychain 录入入口。
- **公开消息**：访问 `codex-resets.com`、`will-codex-reset.com`、`cdn.syndication.twimg.com`；打开原帖时由浏览器访问 `x.com`。不用用户 X Cookie，不附带账户额度或供应商密钥。公开消息不代表用户账户到账。

供应商及公开站点可以获得正常网络请求的 IP 等信息。程序没有分析遥测、作者接收端或自动上传用量功能，不读取聊天内容、不发邮件。

## 本机保存与权限

程序未使用 App Sandbox，使用普通用户的网络、指定配置读取与自身数据写入权限。不需要为查询额度开启辅助功能、屏幕录制或完全磁盘访问。构建为 ad-hoc 签名，未做 Apple 公证，可能触发系统来源检查。

- `~/Library/Preferences/local.codex-battery.plist`：显示设置、便签、保留线、已读与公开消息缓存。
- `~/Library/Application Support/Codex Battery/`：`status.json`、各来源余额/额度缓存及 DeepSeek 估算统计。含账户读数，不能当成可公开诊断包。
- Keychain：B.AI 密钥保存在本工具专属项；Claude 官方使用 Claude Code 已有项。
- `~/Library/LaunchAgents/local.codex-battery.plist`：登录启动项。**首次正常启动会自动配置**，可由菜单关闭。
- `~/Library/Application Support/Codex Battery Backups/`：升级时备份的应用与设置，可能包含个人信息。

沿用上游 bundle id 与数据目录，同一用户下会共享设置。各文件受普通用户文件权限保护，并非全部加密存储。不要上传状态文件、配置、偏好、缓存、备份或含个人数据的截图。

## 测试、估算与删除

离线测试使用合成数据与隔离偏好，不代表真实接口验证；安装测试只操作临时应用目标。演示不进行真实账户查询，退出后恢复真实状态。

DeepSeek 今日花费是余额差分估算，以本地时区当日首次采样起算；首次采样之前及休眠/跨天缺口可能漏算。同间隔充值与消费无法从净余额变化拆分，校准也不保证后续精确账单对账。

卸载前关闭登录启动并退出应用，按使用说明删除本工具自身文件。B.AI Keychain 项需要时在“钥匙串访问”中自行删除；不要删除 Claude Code 或 Codex 的登录及聊天资料。
