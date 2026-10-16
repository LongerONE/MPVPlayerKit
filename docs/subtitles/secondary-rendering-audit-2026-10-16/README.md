# 第二字幕自绘严格审查（2026-10-16）

## 已确认并修复

1. 同会话旧文本回调可能在关闭后重新绘制两路。按路增加文本发布版本；绘制前检查最新轨道/显隐/渲染路径，第二路手动清空同步清理覆盖层。
2. 重建/外挂加载期间新设置的正负延迟、位置、显隐被旧状态覆盖。按路记录等待期间的明确控制值，在选轨事务中合并后一次发布最终状态，避免先发布可见中间态；来源校时缓存也保留新值。
3. QuickPlayer 导入完成可能覆盖后来保存的 ASS 选择。按路偏好版本阻止旧回调回写，同值明确选择也保护；加载完成不再强制显示已隐藏字幕。
4. Temby 资源准备完成时强制重显。按路显隐版本保留用户准备期间的最近操作，恢复回调不再回放旧 hidden 值。
5. 第一字幕设置延迟会先清空解码文本。延迟更新保持现有解码绘制；切换客户端文档时清除旧解码标记，独立文档仍可推进。

没有重置或迁移持久化 ASS 偏好。SRT/VTT 的实际播放器样式不回写长期偏好。

## 修复前复现

- `/private/tmp/SecondaryAudit-repro.xcresult`：3项测试，8个断言失败，覆盖恢复控制和两路导入偏好覆盖。
- `/private/tmp/SecondaryAudit-stale-repro.xcresult`：1项测试，4个断言失败，覆盖实际旧回调及晚到真实解码文本拒绝绘制。
- `/private/tmp/SecondaryAudit-temby-repro.xcresult`：实际 Temby 宿主2个断言失败，隐藏状态被完成回调抹除。
- `/private/tmp/SecondaryAudit-primary-repro.xcresult`：真实引擎1个断言失败，设置相同延迟仍清空第一路文本。

## 最终实际验证

设备：iPhone 17e / iOS 27.0 模拟器，原版 libmpv 和固定本地素材。

- 核心39项通过，0失败，含新增5项时序审查测试。真实两路标签验证正负延迟、12轮快速切换、关闭无残留、恢复期间最新控制、恢复后校时归属、客户端文档切换及较新 ASS 偏好优先。
- Temby4项通过，0失败，含实际准备期间隐藏/修改模式、公共阴影面板、ASS/SSA/SRT/VTT切换、实际 destroy/replay 和延迟恢复。
- LuWu 编译成功，实际宿主23项全部通过，新增实际标签正/负延迟、6轮快速切换、第二路清空不影响第一路、两路持久化控制字典不变。结果见同目录 `luwu-result.json`。

最终结果包：`/private/tmp/SecondaryAudit-core-verified.xcresult`、`/private/tmp/SecondaryAudit-temby-verified.xcresult`。

延迟导入原测试补充等待请求完成，避免在轨道已生效、偏好保存回调尚未执行时误判；原有业务断言全部保留。

需要私有在线片源的 `testLiveEpisodeCustomFontOutline` 未运行。本次不包含真机或在线服务器验收；Temby 空服务器同步 URL 错误不影响固定素材测试。
