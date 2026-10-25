# 仓颉语言程序设计 · 社区便民服务助手

西安交通大学《仓颉语言程序设计》（COMP501727）课程项目，第 12 组。
项目方向以华为 ICT 大赛（创新赛 · 赛题 1「基于华为云产品打造 AI 创新应用」）为主线，本仓库承载其中的**仓颉后端与独立检索包**。

## 项目内容

社区通知、办事指南、维修、养老、活动和失物信息分散在公告栏、居民群、公众号和电话咨询中。项目用统一的仓颉 HTTP 服务承接高频查询，并用独立中文检索包建立确定性检索基线（BM25），再以同证据对照评估云端模型的组织增益（G0 / G1）。

## 目录结构

```
src/
├── cj_zh_search/   独立 cjpm 检索库（词典 + n-gram 分词、倒排索引、BM25）
├── backend/        社区便民服务 HTTP 服务（六意图路由、双域隔离、AI 网关与降级）
└── data/           校园 / 社区隔离的合成数据（非真实社区数据）
```

## 功能模块（C1—C6）

| 编号 | 模块 | 说明 |
|---|---|---|
| C1 | HTTP 服务与契约 | REST 接口、请求校验、统一错误码、日志、健康检查 |
| C2 | 社区意图与任务路由 | 办事咨询、物业维修、养老服务、社区活动、失物信息、闲聊问答 |
| C3 | 中文知识检索包 | 独立 cjpm 库：分词、倒排索引、BM25，可被外部工程以本地路径依赖引用 |
| C4 | 可替换 AI 网关 | 模型调用封装、鉴权、超时、重试、并发、流式转发与结构化降级 |
| C5 | 社区数据与服务状态 | 通知、办事材料、维修单、活动、养老、失物；文件/内存实现 |
| C6 | 测试与基准 | 检索基准与 AI 对照分离，记录 Recall@5、时延、Token 与回退 |

## 统一接口

```
POST /api/v1/chat
GET  /api/v1/notices
POST /api/v1/tickets
```

响应统一封装为 `code / message / data / traceId`。聊天流式传输单独适配 SSE，工单采用非流式 JSON。AI 无业务写入权限，写操作须经服务端校验与用户确认。

## 环境要求

- 仓颉 SDK / cjpm 1.0.5
- stdx 1.0.5.1
- Windows PowerShell 7（构建脚本）或对应 shell

## 构建与验证

```powershell
# 检索库
pwsh -NoProfile -File src/backend/build-library.ps1

# 服务
pwsh -NoProfile -File src/backend/build.ps1

# 回归
pwsh -NoProfile -File src/backend/verify.ps1
```

> 中文绝对路径下 cjpm 依赖扫描会失败，构建脚本会自动切换到 ASCII 临时构建目录，属已知限制，不修改系统编码。

## 当前状态

- 检索库 `cj_zh_search 0.1.0`：`cjpm build` / `test` / `bench` 通过，独立消费者运行通过
- 服务：单元测试与 HTTP 回归通过，五环节端到端（查询→草稿→确认→提交→回执）可复现
- **G0 / G1 真实对照未运行**（无模型凭据与额度），仅完成协议与故障回退的 Mock 验证
- 公共包仓库发布未验证（本机 `cjpm` 无 `publish` 子命令），现为本地发行候选

## 数据说明

`src/data` 全部为**合成数据**，用于课程原型与开发评测，`synthetic=true`、`realBusinessWrite=false`。
不代表任何真实社区的业务流程、通知内容或受理结果。真实数据接入须另行取得来源与许可。

## 许可

见 [LICENSE](LICENSE)。第三方组件声明见 `src/cj_zh_search/THIRD_PARTY_NOTICES.md`。
