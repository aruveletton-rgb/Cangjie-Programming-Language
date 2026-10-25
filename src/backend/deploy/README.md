# 云端部署包（方案 A：华为云 + Windows Server + IP 自签 HTTPS）

- 建立：2026-10-24 14:30；更新：2026-10-24 15:38
- 状态：**本机全链路已实测通过（含 PowerShell 5.1）**；真实云主机尚未部署
- 决策依据：方案 A、V3 系模型、贵阳一、优先免费额度、入口 IP + 自签、**云主机用 Windows 镜像**

---

## 0. 现在能做什么

| 环节 | 状态 |
|---|---|
| 自签证书（IP SAN） | 通过 |
| TLS 反代 → 后端 | 通过（`/health` 与直连一致） |
| 公网 https origin 被后端接受 | 通过（`ICT_PUBLIC_ORIGIN`，见第 2 节） |
| 打包成独立部署包 | 通过（66 个文件，逐文件哈希） |
| 部署包自检（清单/哈希/二进制新鲜度/证书） | 通过（`deploy/preflight-deploy.mjs`，旧包被拦下 2 个真问题） |
| 部署包自包含冒烟（只靠包内 exe+stdx 起服务） | 通过（887 ms 出 `/health`） |
| 在 **PowerShell 5.1** 下启动 | 通过（`tlsHealthOk: true`） |
| 真实云主机部署 | **未做**（没有云主机） |
| 浏览器从远端访问 | **未做**（需要真实 IP + 安全组放行 8443） |

---

## 1. 为什么必须有反代

`src/backend/src/main.cj:72` 把后端写死绑定在 `127.0.0.1`：

```cangjie
let server = ServerBuilder().addr("127.0.0.1").port(port)...
```

所以后端**从设计上不能直接暴露公网**。反代不是可选项，是唯一对外方式；这也保证了没人能绕过 TLS 直接打后端。

**启动顺序不能反**：先后端、后反代。反的先起会返回 `UPSTREAM_UNAVAILABLE`（fail-closed，实测过）。

---

## 2. `ICT_PUBLIC_ORIGIN`（2026-10-24 经用户批准的改动）

改动前：CORS 白名单只接受 `http://127.0.0.1:` 与 `http://localhost:`，公网 https origin 既不能配置（进程启动即 `VALIDATION_ERROR`），也会被请求级 `403` 拒绝。

改动后（`main.cj:19-33`）：

```cangjie
let publicOrigin = (getVariable("ICT_PUBLIC_ORIGIN") ?? "").trimAscii()
if (!publicOrigin.isEmpty()) {
    if (!publicOrigin.startsWith("https://")) { fail("VALIDATION_ERROR") }
    let parts = publicOrigin.split("/", removeEmpty: true)
    if (parts.size != 2 || parts[1] == "*") { fail("VALIDATION_ERROR") }
}
```

规则：

- 默认关闭。不设 `ICT_PUBLIC_ORIGIN` 时**行为与改动前完全一致**，回环守卫不变
- 只接受**一个**精确 https origin，不接受通配、不接受路径、不接受 http
- 其余 origin 仍必须匹配回环前缀，否则启动失败

实测（`audit/backend/20261024T1530_origin_guard/`）：

| 用例 | 结果 |
|---|---|
| `http://1.2.3.4:8443` | 启动退出 1 |
| `https://1.2.3.4:8443/path` | 启动退出 1 |
| `https://*` | 启动退出 1 |
| `https://` | 启动退出 1 |
| 配了公网 origin 后，该 origin 请求 | **401**（此前 403，说明 origin 已放行，只差登录态） |
| 配了公网 origin 后，`https://evil.example` | **403**（外站仍被拒） |
| 回环 origin | 401（行为未变） |
| OPTIONS 预检 | 204 |

---

## 2b. 登录限速（2026-10-24 加固，台账 R-W9-5）

公网可达的部署必须知道这三个环境变量（`start-cloud.ps1` 模板默认值即后端默认值）：

| 变量 | 默认 | 含义 |
|---|---|---|
| `ICT_LOGIN_MAX_FAILURES` | 10 | 同一用户名在窗口内连续失败达到该值即锁定 |
| `ICT_LOGIN_WINDOW_SECONDS` | 300 | 失败计数窗口；窗口外的失败不累计，成功登录即清零 |
| `ICT_LOGIN_LOCKOUT_SECONDS` | 600 | 锁定时长；锁定期间正确口令同样 401 |

- 锁定与错误口令返回同一个 `UNAUTHORIZED`，不产生新的可观测差异。
- 计数器（`lockEventsTotal`/`lockRejectsTotal`/`lockedUsernames`）经 `/api/v1/auth/stats`（仅 staff）可查。
- 已签发的会话不受锁定影响（限速门在登录，不在会话解析）。
- 已知代价：知道用户名的攻击者可以持续锁住该用户名（反代后按源限制无意义）；这是模块头声明过的权衡。
- 用例：`node src/backend/tests/week9.throttle.mjs`（14 项，含 maxFailures=0 拒绝启动）。

---

## 3. 打包与启动（Windows Server）

```powershell
# 在开发机打包（产物在 artifacts/backend/cloud-bundle/）
pwsh -File src/backend/deploy/package-cloud.ps1 -Force

# 打包后必须先自检，再上传（两条都是硬门槛，失败退出 1）
node src/backend/deploy/preflight-deploy.mjs --json
node src/backend/deploy/smoke-bundle.mjs --port 38084

# 上传整个 cloud-bundle 目录到云主机，然后：
cd <bundle>\deploy
.\start-cloud.ps1 -PublicOrigin "https://<公网IP>:8443"
.\stop-cloud.ps1
```

`preflight-deploy.mjs` 检查六件事：manifest 与磁盘逐文件一致、无清单外文件、入口文件齐全、**包内 main.exe 与 `temp/backend/latest-build.json` 认证的哈希一致**、provider 模板仍含适配器读取的 6 个变量、`tls/` 内证书未过期。

`smoke-bundle.mjs` 只把 `stdx/` 加进 PATH 就起包内 exe，证明包**不依赖构建机的运行时**；它不碰 TLS、不需要证书。

包内结构：

```
cloud-bundle/
├─ main.exe                  后端（Windows 产物）
├─ stdx/                     仓颉运行时库（必须与 exe 同目录树）
├─ data/synthetic.runtime.json
├─ tls/                      证书目录（包内默认为空，由 gen-cert.sh 在主机上生成）
├─ deploy/                   启动、停止、反代、自检、模板
├─ state/                    运行期状态（store.json、server.json，首次启动创建）
├─ logs/                     backend / proxy 日志（首次启动创建）
└─ bundle-manifest.json      逐文件哈希
```

`start-cloud.ps1` 会：设环境变量 → 起后端并轮询 `/health` → 起 TLS 反代 → 用 `curl.exe -k` 探 `https://127.0.0.1:8443/health` → 写 `state/server.json` 回执（含 `tlsHealthOk`）。

---

## 4. 三个已踩过的坑（都已修）

| 坑 | 现象 | 处理 |
|---|---|---|
| PowerShell 版本 | 云主机默认是 **5.1**，没有 `-SkipCertificateCheck` / `-NoProxy` / `[IO.Path]::GetRelativePath` | 脚本全部改写为 5.1 可用：探针改用 `curl.exe`，路径用 `Substring` |
| 代理环境变量大小写重复 | 主机同时存在 `HTTPS_PROXY` 与 `https_proxy` 时，启动进程报"字典中的关键字重复" | 启动前删掉小写重复项，保留大写 |
| 后端只监听回环 | 反代先起会 `UPSTREAM_UNAVAILABLE` | 固定顺序：先后端后反代 |
| 部署包陈旧 | 重编译后忘记重新打包，包内 exe 仍是上一版（实测 11,851,776 B，认证版 11,934,720 B），上传后跑的是**没有登录限速/常量时间比较**的旧版 | `preflight-deploy.mjs` 的 `binary-freshness` 与 `binary-size` 检查；打包后必跑 |
| 打包后又手改包内文件 | `start-cloud.ps1` 在打包后修过一次，包内变成 5149 B，而 manifest 仍记 4173 B | 同一检查逐文件校验 size+sha；要改脚本就重新打包，不要手改包内文件 |

---

## 5. 证书

```bash
# Linux / Git Bash
./deploy/gen-cert.sh <公网IP> ./tls
```

- 证书带 **IP SAN**，因为入口是 IP 不是域名
- 浏览器会告警（自签），这是 IP 入口的预期代价
- 有效期 1 年，到期前重生成并重启反代即可

---

## 6. 模型侧（V3 系 + 免费额度）

```bash
node deploy/preflight-provider.mjs          # 只检查配置，不发请求
node deploy/preflight-provider.mjs --live   # 只在 ICT_PROVIDER_REAL=1 时发一次最小调用
```

- 默认**不发任何网络请求**
- 密钥由持有人设置，脚本只打印掩码（长度 + 末 4 位）
- `ICT_PROVIDER_REAL=1` 必须由有权限的人设，代理不代设

---

## 7. 回滚

| 层 | 动作 |
|---|---|
| 代码改动 | 备份在 `audit/backend/20261024T152549_pre_origin_change/main.cj.bak`；还原后用 `build-cjc.ps1` 重编译 |
| 二进制 | 上一版构建记录在 `temp/backend/builds/latest-build.cjpm-20261023.json` |
| 反代 | 停 `tls-proxy.mjs`；后端仍在回环，本机验证不受影响 |
| 状态 | 删 `state/store.json` 即回到干净演示 |

---

## 8. 未验证项（不要当成已通过）

- 真实公网 IP 的证书与安全组入站 8443
- 云主机上的实际部署
- 浏览器端到端（远端机器）
- Linux 编译链路（用户已选 Windows 镜像，本项不再需要）
- 真实模型调用（无凭据，`realG1Ran` 恒为 false）
- 免费额度的限速具体值（需在控制台确认）

---

## 9. 外部终端验收（在**另一台机器**上执行，不是云主机本机）

云主机本机自测通过不等于外部可达。以下四条按顺序跑，任何一条不符就不要继续：

```powershell
# 1) 证书是自签的：严格校验必须失败（退出码 60），这说明 TLS 是真的而不是明文
curl.exe --cacert dummy.pem https://<公网IP>:8443/health
# 期望：curl: (60) SSL certificate problem: self-signed certificate

# 2) 跳过校验能拿到后端响应
curl.exe -k https://<公网IP>:8443/health
# 期望：{"code":"OK",... "authMode":"session", "realG1Ran":false}

# 3) 未列出的 origin 被拒
curl.exe -k -s -o NUL -w "%{http_code}" -X POST https://<公网IP>:8443/api/v1/chat ^
  -H "Origin: https://evil.example" -H "Content-Type: application/json" -d "{}"
# 期望：403

# 4) 未登录访问业务接口被拒
curl.exe -k -s -o NUL -w "%{http_code}" -X POST https://<公网IP>:8443/api/v1/chat ^
  -H "Origin: https://<公网IP>:8443" -H "Content-Type: application/json" -d "{}"
# 期望：401（origin 已放行，只差登录态）
```

第 2 条里 `authMode` 必须是 `session`。如果显示 `demo`，说明 `ICT_PUBLIC_ORIGIN` 没生效或后端版本是旧的——回去跑第 3 节的 `preflight-deploy.mjs`。
