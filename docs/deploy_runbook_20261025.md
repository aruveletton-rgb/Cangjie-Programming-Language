# 部署 Runbook（远端资源到位后照此执行）

日期：2026-10-25　适用：`docs/cloud_plan_course_20261025.md` 的方案 A（Flexus L · Linux）
状态：**脚本已写好，未在实机验证**。首次执行时按"验收"列逐条确认，任何一条不过就停下，不要往下走。

---

## 0. 前置（缺一不可）

| 项 | 谁做 | 备注 |
|---|---|---|
| 华为云账号实名 | 用户 | 个人或企业，决定备案写法 |
| Flexus L 2核2G 包年（Linux） | 用户 | 按需 1 个月先验构建更稳 |
| 域名 `.cn` 并实名 | 用户 | 备案前必须完成域名实名 |
| 安全组放行 80 / 443 | 用户 | 只放这两个，不要放 38082 |
| 主体信息（名称、证件、联系方式） | 用户 | 备案表要逐字一致 |

> 38082 是后端回环端口，**永远不要对公网开放**。公网入口只有 Nginx 的 443。

---

## 1. 系统初始化

```bash
# 专用账号，不要用 root 跑服务
sudo useradd -r -m -d /opt/ict-cloud -s /usr/sbin/nologin ict
sudo mkdir -p /opt/ict-cloud/{state,logs,webapp} /var/www/certbot
sudo chown -R ict:ict /opt/ict-cloud
sudo chown -R www-data:www-data /var/www/certbot
```

**验收**：`id ict` 存在；`ls -ld /opt/ict-cloud` 属主为 ict。

---

## 2. 安装仓颉 SDK（Linux）

从 <https://cangjie-lang.cn/download> 取 Linux 包（LTS 或 STS，与项目 `cjc-version = 1.0.5` 对齐）。

```bash
tar -xzf cangjie-*.tar.gz -C /opt
source /opt/cangjie/envsetup.sh
cjc --version
```

**验收**：`cjc --version` 输出包含 1.0.5（与 `src/backend/cjpm.toml` 的 `cjc-version` 一致）。
**若版本不一致**：不要硬改 toml 里的版本号，先确认 SDK 与源码兼容，否则可能编过但行为不同。

---

## 3. 安装 stdx（Linux 版）

```bash
# 解压后定位到 .../linux_x86_64_cjnative/dynamic/stdx
export STDX_DIR=/opt/cangjie-stdx/linux_x86_64_cjnative/dynamic/stdx
ls "$STDX_DIR"/stdx.net.http.cjo
```

**验收**：`stdx.net.http.cjo` 与 `stdx.encoding.json.cjo` 都在。

---

## 4. 构建并测试

```bash
git clone git@github.com:aruveletton-rgb/Cangjie-Programming-Language.git /srv/ict-src
cd /srv/ict-src/src/backend/deploy
chmod +x *.sh
./build-linux.sh --test
```

**验收**（三条都要过）：
1. `buildExitCode: 0`
2. `testExitCode: 0`
3. 输出的 `binary` 路径存在且 `sha256` 有值

**这一步就是方案 A 的唯一风险点。** 如果 2G 内存编译时被 OOM kill：加 swap 再试一次
（`fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`），
仍然不行就退回方案 B（Windows），不要在这上面耗超过一天。

---

## 5. 打包

```bash
./package-cloud-linux.sh --build-root /tmp/ict_backend_xxx --out /srv/ict-cloud-bundle
```

**验收**：输出 `files=` 数量与 `main sha256`；`bundle-manifest.json` 里 `main` 的哈希与上一步一致。

---

## 6. 部署到 /opt/ict-cloud

```bash
sudo cp -r /srv/ict-cloud-bundle/* /opt/ict-cloud/
sudo cp /opt/ict-cloud/deploy/provider.env.example /opt/ict-cloud/deploy/runtime.env
sudo chown -R ict:ict /opt/ict-cloud
sudo chmod 600 /opt/ict-cloud/deploy/runtime.env   # 里面以后可能放模型 Key
```

编辑 `runtime.env`，至少设置：

```ini
ICT_PORT=38082
ICT_DATA=/opt/ict-cloud/data/synthetic.runtime.json
ICT_STORE=/opt/ict-cloud/state/store.json
ICT_PUBLIC_ORIGIN=https://<你的域名>
ICT_AUTH_MODE=session
ICT_SESSION_TTL=3600
ICT_LOGIN_MAX_FAILURES=5
```

**验收**：`ICT_PUBLIC_ORIGIN` 与 `ICT_AUTH_MODE` 同时正确——只设前者不设后者也可以（会自动推导为 session），
但**显式写出来更安全**，因为默认值依赖代码分支。

---

## 7. 注册 systemd 服务

```bash
sudo cp /opt/ict-cloud/deploy/ict-backend.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ict-backend
systemctl status ict-backend --no-pager
curl -s http://127.0.0.1:38082/health
```

**验收**：`active (running)`；`/health` 返回 `"code":"OK"`。
**常见失败**：`VALIDATION_ERROR` 立刻退出 = `ICT_PUBLIC_ORIGIN` 格式不对（必须 `https://` 开头、无路径、无通配符）；
或者 `demo` 模式与公网 origin 同时存在（这是设计上的启动错误）。

---

## 8. Nginx + 证书

```bash
sudo apt install -y nginx certbot
sudo cp /opt/ict-cloud/deploy/nginx-campus.conf /etc/nginx/conf.d/campus.conf
sudo sed -i 's/<DOMAIN>/你的域名/g' /etc/nginx/conf.d/campus.conf
sudo nginx -t && sudo systemctl reload nginx

sudo certbot certonly --webroot -w /var/www/certbot -d 你的域名
sudo systemctl reload nginx
```

**验收**：`curl -I https://你的域名/health` 返回 200；`curl -I http://你的域名/health` 返回 301。

---

## 9. 托管 Web 演示与隐私政策

```bash
# 本地构建 web-demo 后上传 dist
npm ci && npm run build          # 在 src/web-demo 下
scp -r dist/* root@<ip>:/opt/ict-cloud/webapp/
# 隐私政策页（本次已生成草案，主体信息填完再上传）
scp docs/privacy/privacy-policy.html root@<ip>:/opt/ict-cloud/webapp/privacy.html
sudo chown -R ict:ict /opt/ict-cloud/webapp
```

**验收**：`https://你的域名/app/` 能打开；`https://你的域名/privacy` 能打开且含备案号位置。

---

## 10. 上线验收清单（全过才算"公网可用"）

| # | 检查 | 命令 / 方式 | 期望 |
|---|---|---|---|
| 1 | 健康检查外网可达 | `curl -s https://域名/health` | `code=OK` |
| 2 | 回环端口未暴露 | 外网 `curl http://IP:38082/health` | 连接超时/拒绝 |
| 3 | 公网模式强制会话认证 | 用 demo 静态令牌调 `/api/v1/chat` | 401 |
| 4 | 越权访问被拒 | 用 A 用户令牌查 B 用户工单 | 403 |
| 5 | 重复提交仅一笔 | 同幂等键并发 8 次 | 同一 ticketId，工单数 1 |
| 6 | 五环节端到端 | 查询→草稿→确认→提交→回执 | 回执 `COMMITTED` |
| 7 | 证书有效 | `curl -vI https://域名` | 证书链通过，无告警 |
| 8 | 备案号可访问 | 打开 `/app/` 底部 | 备案号可见 |
| 9 | 隐私政策可访问 | 打开 `/privacy` | 正文完整，非占位 |
| 10 | 服务自启 | `sudo reboot` 后复查 1—3 | 全部仍通过 |

---

## 11. 回滚

```bash
sudo systemctl stop ict-backend
sudo cp -r /opt/ict-cloud.bak/* /opt/ict-cloud/     # 上一版备份
sudo systemctl start ict-backend
```

**部署前先备份**：`sudo cp -r /opt/ict-cloud /opt/ict-cloud.bak.$(date +%Y%m%dT%H%M)`。

---

## 12. 实机验证结果（2026-10-25 已回填）

主机 `124.70.187.77`（Ubuntu 24.04.4 / 2核2G / 华东-上海一），完整记录见
`audit/backend/cloud_deploy_20261025/report.md`。

| 项 | 状态 |
|---|---|
| `build-linux.sh` 在 Linux 实机 | **通过**：build exit 0，`cjpm test` 35/35 PASSED |
| 仓颉 Linux 产物路径 | **确认**：`target/release/bin/main`（脚本第一种候选即命中） |
| 2G 内存是否够编译 | **够**（加了 2G swap；未单独验证无 swap 情况） |
| Ubuntu 24.04 兼容性 | **通过**：`ldd cjc` 零缺失库 |
| `cjc --version` | `1.0.5 (cjnative)`，target `x86_64-unknown-linux-gnu` |
| 部署包自包含 | **原不成立**，已修：缺 `libcangjie-runtime.so`，见下方 |
| systemd 单元 | **通过**：`ProtectSystem=strict` 下正常启动并 active |
| Nginx SSE 不缓冲 | 未验证（域名与证书未到位，未装 nginx） |
| 公网 HTTPS 可达 | 未验证（同上） |

### 部署包缺运行时库（已修）

`package-cloud-linux.sh` 初版只打包 stdx，漏了仓颉运行时库，服务启动报
`error while loading shared libraries: libcangjie-runtime.so`，`systemctl` 反复 `status=127`。

修复：打包时把 `$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative/*.so` 并入包内 `stdx/`。
修复后 `ldd /opt/ict-cloud/main` 零缺失，包内 `stdx/` 共 83 个 `.so`（stdx 35 + runtime 48）。

> 若手工部署而不用打包脚本，必须保证 `LD_LIBRARY_PATH` 同时包含
> `stdx` 目录与 `$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative`。

### 下载源的两个坑

1. `cangjie-lang.cn` 下载直链是**签名 URL**，只能从页面 JS 生成的 `<a href>` 里取，猜不出来。
2. gitcode 对普通宽带的 IP 返回 **418**，对华为云主机 IP 返回 **200**。大文件让服务器自己下：
   本机 SFTP 上传实测 33 KB/s（268MB ≈ 2.3 小时），服务器直下 1.2—1.5 MB/s（≈3 分钟）。
