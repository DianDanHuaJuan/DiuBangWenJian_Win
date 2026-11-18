# Windows 缩略图与预览图生成：规划与施工方案

> 状态：**定案修订（2026-11-18 夜）** · 调度/日志/索引防抖已按 §14 二次实测回改  
> 适用范围：Windows 客户端/NAS（`DiuBangWenJian_Windows`）作为 **NAS 主机** 时的 grid/preview 生成、落盘与调度  
> 对端浏览方：安卓 / Windows 客户端（HTTP 契约不变，仍走 `GET /api/v1/thumbnail?type=grid|preview`）  
> 关联：[`缩略图与预览图缓存方案.md`](../../DiuBangWenJian/docs/缩略图与预览图缓存方案.md)（安卓仓；本方案修订其中 Windows 主机侧「preview 可落盘」「允许受控预热」）  
> 参考：旧项目 `D:\tmp\DiuBangNASServer_Windows`；Immich / Nextcloud 有界并发、按需优先、后台时间片；Flutter isolate 背压实践  
> 约束：测试阶段可不兼容旧版

---

## 0. 问题与目标（一句话）

Windows 作 NAS 时，媒体墙曾因 library stub / 未统一生成而出现「上半有图、下半 404」。  
本方案：建立 **按需必做** + **仅 grid 的受控预热**；grid/preview **均可落盘**；**grid/preview 分闸**但 **生成并发一律 1**（remote=warmup=全局）；remote 优先、warmup 让路；预热 **涓流**；索引 **脏标记 + 3s 防抖落盘**；**关闭热路径日志**；**不做缩略图容量淘汰**；用 **key→path 索引 + 日扫** 清理孤儿；打开 APP **不跑重扫描**。

---

## 1. 需求定案（现行）

### 1.1 必须（P0）

| 项 | 定案 |
|----|------|
| 按需生成 | 远程或本机浏览命中未缓存的 grid/preview 时，**当场生成**、写入 `.thumbs`、再返回 |
| library 通路 | 有 `absolutePath` 则走统一 `ThumbPipeline` / Generator（禁止 stub 成功路径） |
| `fs` / 共享根 | 与 library 共用生成器与落盘规则 |
| 落盘档位 | **grid + preview 均服务端落盘**；预热 **只生成 grid**，preview **仅按需入库** |
| 生成闸 | grid / preview **各自一闸**；**remote ≡ 1**；**全局同时生成 ≡ 1**（`ThumbGlobalBudget`） |
| 远程优先 | `priority=remote`（含本机走同一 Handler 的浏览）≫ `warmup`；任一闸有 remote 需求时 warmup 不领新槽 |
| 预热槽 | warmup **仅 grid 闸**，**≡ 1**；preview 闸 `maxWarmup=0` |
| 真背压 | 单闸 remote 队列有界领槽；全局满则等待；禁止扫盘时大量 `unawaited` 堆积 Future |
| 索引落盘 | 内存先改；**变动后 3s 防抖整文件写**；无脏不写；退出 / 换根 `flush` |
| Handler 日志 | **关闭** thumb HTTP 逐条打印；host/files/extvol 成功路径默认静默（`verboseHttp`/`verboseExtvol`） |
| 日志防爆 | `AppLogger` 全局限速 ≤40 行/秒；`StorageVolumes` **8s 进程级缓存**；闸 remote 排队 >24 快失败 |
| 压测方式 | 优先 `--profile`/`--release`；**禁止**长时 `flutter run \| Tee log.txt` 当性能证据 |

### 1.2 应做（P1）

| 项 | 定案 |
|----|------|
| 空闲预热 | 仅补 **缺失的 grid**；无待办则 **不启动** worker |
| 涓流 | **仅 warmup**：每成功/结束一轮生成后 **sleep 200ms**；**remote 按需不做涓流** |
| 漏缺发现 | **日扫**为主（+ 换共享根）；打开 APP **尽量延后、分片**，不干扰首帧与随后操作 |
| 孤儿清理 | **必须做**；维护 `key → path` 索引；全盘孤儿校对放在 **日扫**，不放每次打开 APP |
| 磁盘空间 | **不对 `.thumbs` 做数量/字节上限与 trim**；原图等大文件写入失败时弹窗「磁盘空间不足」 |

### 1.3 非目标（本期不做）

- 人脸/相似图/智能检索  
- 批量 multipart thumbnails API  
- 安卓 NAS 主机同一套预热（安卓仍 MediaStore；契约兼容即可）  
- HLS 转码预热  
- 保证 HEIC 全量可解（无力则 404，失败记入退避/永久失败）  
- 缩略图侧容量治理 / 满额删最旧（已明确取消）

---

## 2. 与现网 / 实测关系

### 2.1 历史缺口

```
GET …/thumbnail?type=grid&rootId=library&name=…
  → mediaLibrary.thumbnailFor → Windows stub null
  → 404（未命中旧盘缓存时）→「半屏有图」
```

### 2.2 初版预热实测结论（log，须回改）

| 现象 | 结论 |
|------|------|
| `Failed to post message to main thread` 刷屏 | Windows 任务队列被 **密日志 + 重 IO（含每次 write 全盘 trim）+ 连续生成** 打满；不完全等于「同步解码冻死」 |
| `heartbeat.gapMs≈1000` 仍可出现大量 Failed to post | 主 isolate 定时器未必停，但引擎 PostMessage 已失败 → UI 顿挫/假死感 |
| 媒体库约 1 万条，`listAll` ~2s | 打开 APP / 常驻循环扫库过重 |
| 每次 `cache_trim` 数百 ms、`files` 数千 | **每次 write 全量 trim 不可接受** → 已改为不做缩略图 trim |
| 预热同时投 preview + 背压只看 pending | 忙且易堆积 → 预热仅 grid + 真背压 |
| 部分大视频 ffmpeg `exit=-1094995529`（INVALIDDATA）、`stdout=0`、数十 ms 失败 | 打开/解析失败，非抽帧算法本身；应失败退避，避免死磕 |

### 2.3 HTTP 契约（不变）

```
GET /api/v1/thumbnail?type=grid|preview&rootId=&name=
```

- 成功：`image/jpeg`  
- 失败：`404` / `400` / `401`（排队超时推荐仍 404 + thumb_diag）  
- 失败不升级：grid 失败不拉 preview；preview 失败不自动拉原图 content  

### 2.4 不做 preview 预热时的体感（Win + 机械盘，参考实测）

| 场景 | 粗估 |
|------|------|
| 首进画廊、preview 现算（普通 JPEG） | 约 **0.5–1s** 出预览图 |
| 同图第二次（盘命中） | 常 **数十 ms 内** |
| 视频抽帧成功 | 小文件可约 **0.1–0.2s 级**；大文件/坏封装可达数秒或失败 |

---

## 3. 总体架构

```
                    ┌──────────────────────────────────────┐
                    │   ThumbGlobalBudget（全局 ≡ 1）         │
                    └──────────────────┬───────────────────┘
                                       │
              ┌────────────────────────┴────────────────────────┐
              │                                                 │
   ┌──────────▼──────────┐                         ┌────────────▼────────────┐
   │ Gate grid           │                         │ Gate preview            │
   │ remote=1 warmup=1   │                         │ remote=1 warmup=0       │
   └──────────┬──────────┘                         └────────────┬────────────┘
              │         全局 Budget ≡ 1（两闸共享）              │
              │                                                 │
   远程 GET grid / 预热 Worker                         远程 GET preview
   remote ≫ warmup；涓流仅 warmup
              │                                                 │
              └────────────────────────┬────────────────────────┘
                                       │
                         图片：isolate 解码缩放
                         视频：ffmpeg 抽帧 →（缩放/编码须离主 isolate）
                                       │
                         写 .thumbs/{grid|preview}/ + 索引（3s 防抖）
```

---

## 4. 生成闸与调度

### 4.1 语义

1. 凡 grid/preview 的 CPU/ffmpeg 密集段必须经**对应档位闸**，并占用全局预算。  
2. **remote ≡ 1**；**warmup ≡ 1**；**全局同时生成 ≡ 1**（避免机械盘并行互相拖慢）。  
3. 双优先级：remote ≫ warmup（任一闸有 remote 则 warmup 不领槽）。  
4. 有 remote 待办/运行中：warmup **停止领槽**；已跑 warmup 协作取消（可取消点检查）。  
5. 同 `cacheKey` 单飞合并。

### 4.2 涓流（仅 warmup）

```
取 1 个待办 → Gate(warmup) → 生成 → 写盘/更新索引 → sleep(200ms) → 下一条
```

- remote 路径：**禁止** 额外 200ms。  
- 队列空：**停止 worker**，不要空转全库 list。

### 4.3 超时

单任务生成建议 **8～15s**；超时释槽并 404（remote）或标失败（warmup）。

---

## 5. 落盘、键与索引

### 5.1 目录

```
{shareRoot}/.thumbs/grid/{sha256}.jpg
{shareRoot}/.thumbs/preview/{sha256}.jpg
```

- `.thumbs` 对分享列表 / 媒体扫描隐藏。  
- 换共享根 → 换缓存树与索引；旧根不主动跨根清理。

### 5.2 缓存键

```
algoVersion | type | rootId | relativePath | mtimeMs | sizeBytes
→ SHA-256 hex
```

写入：`*.part` → rename。

### 5.3 容量与 trim（现行：不做）

| 项 | 定案 |
|----|------|
| grid/preview 数量上限 | **无** |
| 字节上限 / 每次 write 全盘 trim | **无**（已否决；相对原图占比可忽略） |
| 磁盘不足 | 仅 **原图等大文件写入失败** 时弹窗提示用户；缩略图写失败记日志即可 |

### 5.4 key → path 索引（应做）

| 操作 | 索引 |
|------|------|
| 写入 grid/preview 成功 | 内存登记；**3s 防抖**后整文件落盘（无脏不写） |
| 应用内删除原图 | 按 meta 算 key，删 grid+preview 文件 + 删索引项（同样防抖） |
| 日扫孤儿 | 索引条目源文件不存在 → 删缓存文件 + 删索引 |
| 换根 / 退出 | `flush` 后再切根；退出路径强制 flush |

体积：万级条目约数百 KB～数 MB，可接受。  
**不能**仅靠 sha256 文件名反推路径，故孤儿清理依赖本索引（或以媒体集合算合法 key 集，一期以索引为准）。

---

## 6. 按需生成（必须）

```
鉴权 → type/rootId/name
  → 解析 File（library：absolutePath；fs：resolve；extvol：按现能力）
  → 读盘命中？ → 200
  → Gate(remote) → 生成 → 写盘 + 索引 → 200
  → 失败 → 404
```

视频：ffmpeg 失败（含 INVALIDDATA）→ 404；warmup 侧记失败次数 / permanent_failed，避免反复占闸。

---

## 7. 预热与扫描节奏

### 7.1 预热范围

- **只预热缺失的 grid**。  
- **不预热 preview**（按需生成并入库）。  
- 待办为空 → **不启动**预热。

### 7.2 漏缺发现（谁把任务放进队列）

| 时机 | 行为 |
|------|------|
| **日扫**（距上次 ≥ 24h，可配置） | 扫描媒体，缺 grid 入队；顺带孤儿清理（§5.4） |
| **换共享根** | 重置队列/索引上下文；可触发一次漏缺发现 |
| **打开 APP** | **不**做全盘孤儿扫；**不**在首帧做全库漏缺重扫描；若需补货，**尽量延后**（deferred 更靠后 / 空闲后），分片让出，避免干扰用户操作 |
| NAS 关闭 | 停止 worker，清或冻结 warmup 队列 |

### 7.3 与按需关系

- 同一套 `.thumbs` 与索引。  
- 同键单飞。  
- 浏览/remote 始终优先于预热涓流。

---

## 8. 模块划分

| 模块 | 职责 |
|------|------|
| `ThumbCacheStore` | 键、读写 `.thumbs`；**无容量 trim**；跳过扫描隐藏 |
| `ThumbKeyIndex` | `key→path`；脏标记 + 3s 防抖落盘；退出/换根 flush |
| `ThumbGenerator` / `ThumbnailService` | 图 isolate；视频 ffmpeg；缩放编码离主 isolate |
| `ThumbGlobalBudget` | 全局同时生成 ≡ 1 |
| `ThumbGenerationGate` | 分 grid/preview；remote=1；warmup 仅 grid=1；remote≫warmup |
| `ThumbPipeline` | 查盘 → 档位闸 → 生成 → 写盘+索引；单飞 |
| `ThumbnailHandler` | 按需 remote；**无** per-request HTTP 日志 |
| `ThumbWarmupScheduler` | 仅 grid 队列；完成后 200ms；无待办停机 |
| `ThumbDailyScan`（名可调） | 日扫漏缺 + 孤儿；换根触发 |
| `WindowsFolderMediaLibrarySource` | 委托 Pipeline；扫描跳过 `.thumbs` |

---

## 9. 施工分期（修订）

### 期 A — 按需打通（已基本落地，保持）

按需 Handler + Pipeline + shareRoot 落盘 + library 非 stub。

### 期 B — 调度回改（优先，据实测）

1. 闸 **grid/preview 分闸**；**remote=warmup=全局≡1**  
2. 预热 **仅 grid**；完成后 **200ms** 涓流；remote 不睡  
3. **移除**每次 write 的容量 trim / 数量上限逻辑  
4. **关闭** Handler thumb HTTP 逐条日志；`thumb_diag` 仅重要/慢路径  
5. 视频后处理离主 isolate（防日后大帧卡死）  
6. ffmpeg/生成失败退避  
7. 索引 **3s 防抖**落盘；退出 flush 

### 期 C — 索引、日扫、体验

1. `key→path` 索引；应用内删除同步清缓存  
2. 日扫：漏缺入队 + 孤儿清理；齐了不预热  
3. 打开 APP：仅轻量/延后逻辑，不挡操作  
4. 原图写盘失败 → 磁盘空间不足弹窗（若尚未统一）  
5. 可选：预热开关设置项  

---

## 10. 验收清单（修订）

### 10.1 按需

- [ ] 清空 `.thumbs` 后媒体墙格子最终能出图（可排队）  
- [ ] library 无 stub 成功路径  
- [ ] preview 按需生成并落盘；第二次打开明显更快  
- [ ] 无 ffmpeg 时视频 404，图片不受影响  
- [ ] 任意时刻全局生成并发 ≡ 1（remote 与 warmup 均不超过 1）  

### 10.2 预热与抢占

- [ ] 预热只写 grid，不主动写 preview  
- [ ] warmup 完成后可见 ~200ms 间隔；remote 请求无额外 200ms  
- [ ] remote 到达时 warmup 停止领槽  
- [ ] 无待办时不空转扫库  
- [ ] 打开 APP 后短时间内 UI 可操作（重扫描不堵首帧）  

### 10.3 索引与孤儿

- [ ] 写入更新索引；应用内删原图清 grid+preview+索引  
- [ ] 日扫清理源已不存在的孤儿  
- [ ] 打开 APP 不跑全盘孤儿扫  

### 10.4 空间

- [ ] 无缩略图容量 trim / 数量封顶逻辑  
- [ ] 原图写入盘满有明确用户提示  

---

## 11. 风险与对策

| 风险 | 对策 |
|------|------|
| 预热拖慢浏览 / PostMessage 刷屏 | 分闸+全局封顶 + 涓流 + remote 优先 + 关 HTTP 日志 + 禁 trim |
| 主线程同步解码（视频 JPEG） | 缩放/编码进 isolate |
| ffmpeg INVALIDDATA / 坏封装 | 快速失败 + 退避/永久失败，不反复占闸 |
| 孤儿占盘 | 索引 + 日扫；应用内删除即时清 |
| `.thumbs` 无限涨 | 接受相对原图可忽略；真正空间危机盯原图写入 |
| 打开 APP 卡顿 | 漏缺/孤儿不放启动关键路径；延后分片 |

---

## 12. 文档修订关系

| 文档 | 关系 |
|------|------|
| 安卓仓 `缩略图与预览图缓存方案.md` | URL/type/失败不升级仍有效；Windows 主机 preview 可落盘 + 仅 grid 受控预热 |
| 旧 NAS `DiuBangNASServer_Windows` | 落盘布局参考；并发与预热节奏以本文为准 |
| 本文件 | Windows 施工与调度 **唯一详细依据** |

---

## 13. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-11-18 | 初稿：按需；双档落盘；闸；remote 优先；⌊cores/2⌋ 预热；512MB trim；分期 A/B/C |
| 2026-11-18 | 期 A/B 初版代码落地 |
| 2026-11-18 | **讨论修订**：N≡1；预热仅 grid + 200ms 涓流；取消缩略图容量/数量限制与 trim；key→path 索引；孤儿与漏缺以日扫为主；打开 APP 延后轻量；原图盘满弹窗；写入实测 RCA（Failed to post / trim / 背压 / ffmpeg INVALIDDATA） |
| 2026-11-18 | **二次实测回改**：关 thumb HTTP 日志；索引 3s 防抖；remote≤3；grid/preview 分闸；全局≤4；退出 flush 索引 |
| 2026-11-18 | **P0/P1 日志与队列防爆**：AppLogger 分级+限速；host/files/extvol 成功路径默认静默；Volumes 8s 缓存；thumb 慢路径合并；闸 pending>24 快失败；压测勿长 Tee |
| 2026-11-18 | **并发回退 ≡1**：实测 remote=3 在机械盘上单张变慢、CPU 升高；remote/warmup/全局一律 1 |

---

## 14. 讨论结论摘要（便于对照）

1. **预热不做 preview**；preview 库保留，远程/本机按需生成时入库。  
2. **不做缩略图 trim / 数量上限**；相对原图可忽略；空间不足只在原图写入失败时提示用户。  
3. **孤儿必须清**：`key→path` 索引，写/删维护（**3s 防抖落盘**）；全盘孤儿扫放在 **日扫**，不放每次打开 APP。  
4. **打开 APP 查 grid 缺漏尽量延后**，不得干扰打开后用户操作。  
5. **分闸保留，并发一律 1**；warmup 涓流 200ms；remote 不涓流。  
6. Failed to post 报错海：引擎 `PostMessage` 失败自激；应用侧用 **日志分级/限速 + Volumes 缓存 + 闸快失败** 降唤醒；测性能 **勿长 Tee**，优先 profile/release。  
7. 明细日志开关：`AppLogger.verboseHttp` / `verboseExtvol` / `verboseThumb`（或 `ThumbDiag.verbose`）。  
8. **Release 可大幅减轻** Dart `debugPrint` 引发的唤醒，但 **不能从根上保证** PostMessage 永不失败（生成完成回调仍在）；配合并发=1 + 勿 Tee 后，生产上通常可接受。
