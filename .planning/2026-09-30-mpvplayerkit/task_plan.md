# MPVPlayerKit 严格代码审查

## Goal
审查现有实现，交付有源码证据、优先级、修复步骤和验收标准的详细计划；审查已完成，用户于 2026-09-30 授权按照计划实施。

## 假设与范围
覆盖 Sources、Tests、包配置与 Demo；追踪 Temby_iOS / LuWu_iOS 对公开接口的使用。只审查自有代码，不审查二进制依赖内部。运行验证以构建和现有测试为主，交互缺陷标记待设备复现。

### Phase 1: 项目与基线
**Status:** complete
### Phase 2: 核心与集成路径审查
**Status:** complete
### Phase 3: 验证候选问题与构建
**Status:** complete
### Phase 4: 修复计划与交付
**Status:** complete

## Next Step
自动回归与构建通过后提交；等待用户恢复 iPhone 15 Pro 可信连接，再安装并进行手动验收。

## Errors Encountered
暂无。

- 工具错误：图 CLI 私有缓存 chmod 被沙盒限制；经受控提权只读查询成功。清单命令中误包含不存在的 Tests 路径，已改为具体项目路径。

- 图工具 index_status 缺少 project 参数：补充现有项目名后成功。

- 文档核对脚本错误：cwd 已在项目内，却拼接重复项目前缀；改用绝对项目路径后成功。

## 实施授权与方案
用户明确要求按照计划实施。沿用最小方案：HLS 有外置 rendition 时保留 master；独立字幕头通过受控临时文件继续交由 libmpv 渲染；autoplay 仅首次生效。保持宿主接口及缓存持久化行为，不更换二进制依赖。

### Phase 5: A 字幕解析与测试入口
**Status:** complete
### Phase 6: B 队列与会话隔离
**Status:** complete
### Phase 7: C 字幕取消、可见性与请求头
**Status:** complete
### Phase 8: D HLS rendition 与请求上下文
**Status:** complete
### Phase 9: E QuickPlayer 生命周期与 PiP 恢复
**Status:** complete
### Phase 10: F 验证、双宿主构建与交付
**Status:** in_progress
自动化与构建已通过；真机安装/手动验收等待用户连接、解锁和信任设备。
