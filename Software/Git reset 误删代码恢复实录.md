# Git reset --hard 误删代码恢复实录：从「新文件还在、改动凭空消失」到 git fsck 捞回悬空 blob

> 一次真实的本地代码丢失事故。表象是 mybill 服务的 `SysSubscriptionController.java` 编译爆红、明明刚写好的「订阅明细增强」方法不见了，但同一批新建的 DTO/VO 文件却好端端躺在工作区。最终定位到 **一次 `git reset --hard origin/develop` 把未提交的「已跟踪文件改动」全部清掉，而未跟踪的新文件不受影响**，造成「新类还在、调用它们的代码消失」的割裂状态。
>
> 关键转折：这些改动**曾被 `git add` 暂存过**，所以以 **dangling blob** 的形式残留在 `.git/objects` 里，用 `git fsck --lost-found` + `git cat-file` 完整捞回，没有重写一行代码。
>
> 本篇覆盖：现象 → 第一刀「git status / reflog 还原案发现场」→ 第二刀「git fsck 找悬空对象」→ 第三刀「按内容特征锁定丢失版本」→ 恢复 → 底层原理（reset 三种模式 / 未跟踪文件 / blob 何时进对象库 / 什么情况下捞不回）→ 复盘 → 预防。

---

## 一、现象

正在做 mybill 服务的「订阅明细增强 —— 渠道与 pay_order 聚合」需求，写了一半切去处理别的分支，回来后：

- IDE 里 `SysSubscriptionController.java` 大面积爆红
- 报错集中在 `vo.setRenewalCount(...)`、`vo.setTotalPaidAmount(...)` —— 找不到方法
- 刚写的 `/detailList`、`/detailExport` 接口和 `loadSubscriptionDetails`、`toExportRow` 等私有方法**整段不见了**
- 但是！为这个需求**新建**的 `SubscriptionDetailQueryDto.java`、`SubscriptionRenewalExportVo.java`、`util/ExcelExportUtil.java` 三个文件**还在工作区**

**最反常的细节**：新建的类文件还在，但**引用这些类、调用它们的控制器代码消失了**。这种「一半在一半不在」的割裂，几乎可以直接锁定是 **`git reset --hard` 干的**——因为它对「已跟踪文件」和「未跟踪文件」的处理方式不同（见第五节）。

---

## 二、第一刀：`git status` + `git reflog` 还原案发现场

### 2.1 先确认工作区状态

```bash
git status --short
```

```
 M application/mybill/mybill-service/pom.xml
?? application/mybill/mybill-service/src/main/java/.../dto/SubscriptionDetailQueryDto.java
?? application/mybill/mybill-service/src/main/java/.../util/
?? application/mybill/mybill-service/src/main/java/.../vo/SubscriptionRenewalExportVo.java
?? docs/superpowers/plans/2026-06-10-订阅明细增强-渠道与pay_order聚合.md
```

关键信息：

- `SysSubscriptionController.java` **不在列表里** → 它和 HEAD 完全一致，没有任何未提交改动
- 三个新文件是 `??`（未跟踪），仍然存在
- 也就是说，控制器被「还原」到了 HEAD 版本，本地改动没了

### 2.2 `git reflog` 看 HEAD 都经历了什么

`reflog` 记录每一次 HEAD 移动，是「时间机器」：

```bash
git reflog -8
```

```
53579a367 HEAD@{0}: reset: moving to origin/develop          ← 案发点
5f2d1483a HEAD@{1}: commit (amend): feat: 健康资料新增healthLevel字段
53579a367 HEAD@{2}: commit: @
bb80cb506 HEAD@{3}: commit: feat: RENEW_FAILURE转URL类型跳转
...
```

`HEAD@{0}` 是一次 **`reset: moving to origin/develop`**。结合「工作区已跟踪文件被还原、未跟踪文件保留」的现象，可判定执行的是 `git reset --hard origin/develop`。

> 💡 心得：怀疑代码被「还原/删除」时，**第一时间 `git reflog`**，不要急着重写。reflog 默认保留 90 天，几乎一定能找到案发前的引用。reflog 是排查这类事故的「监控录像」。

### 2.3 排除「是不是 reset 丢了已提交内容」

reflog 里 `HEAD@{1}` 那个 amend 出来的 `5f2d1483a` 也被 reset 抛弃了，先确认它和当前 HEAD 树是否一致：

```bash
git diff --stat 53579a367 5f2d1483a
# 无输出 → 两者树完全相同，reset 没有丢失任何"已提交"内容
```

结论收窄：**丢的不是某个 commit，而是「从未提交、只存在于工作区/暂存区」的改动**。这类内容 reflog 是查不到的（reflog 只记录 ref 移动，不记录工作区），得换工具。

---

## 三、第二刀：`git fsck --lost-found` 找悬空对象

未提交的改动，只要曾经被 `git add` 暂存过，就会立刻在 `.git/objects` 里生成对应的 **blob 对象**。`reset --hard` 把 index 和工作区都重置了，但**那些 blob 对象不会立即删除**——它们变成「悬空对象（dangling object）」，要等 `git gc` 才清理（默认 2 周）。

```bash
git fsck --lost-found --no-reflogs
```

```
dangling blob a00d0ce79bd9...
dangling commit 5f2d1483a4bb...
dangling blob 14021f1d0a65...
dangling blob e814db973a15...
... （几十个）
```

- `--lost-found`：把悬空对象内容导出到 `.git/lost-found/`（也会在 stdout 列出哈希）
- `--no-reflogs`：把 reflog 也当作「不可达」，这样**仅被暂存过、从未被任何 ref/reflog 引用的 blob** 才会显现出来

一堆悬空 blob，下一步是从里面挑出「丢失的那两个文件」。

---

## 四、第三刀：按内容特征锁定丢失版本

丢失的代码有明显「指纹」——它引用了那几个新建类。遍历所有悬空 blob，`cat-file` 出内容，grep 这些独有标识：

```bash
for b in $(git fsck --lost-found --no-reflogs 2>/dev/null | grep "dangling blob" | awk '{print $3}'); do
  if git cat-file -p $b 2>/dev/null | grep -qE "SubscriptionRenewalExportVo|SubscriptionDetailQueryDto|ExcelExportUtil"; then
    echo "MATCH blob=$b lines=$(git cat-file -p $b | wc -l)"
  fi
done
```

命中（节选）：

```
MATCH blob=14021f1d... lines=2012   ← SysSubscriptionController 的丢失版本（含全部新方法）
MATCH blob=e814db97... lines=139    ← 后面发现的 SubscriptionVo 丢失版本
MATCH blob=7a48bb02... lines=51     ← SubscriptionRenewalExportVo（新文件，工作区也有）
MATCH blob=a7eb1faf... lines=39     ← SubscriptionDetailQueryDto（同上）
```

- `git cat-file -p <hash>`：按 blob 内容打印（`-p` = pretty，自动识别对象类型）
- `git cat-file -t <hash>`：只看类型（blob / tree / commit / tag）

确认 `14021f1d` 就是丢失的控制器（2012 行，当前工作区只有 1718 行，多出约 294 行就是丢的）。

### 用 diff 确认是「纯新增」再恢复

恢复前先对比，确认不会覆盖掉别的内容：

```bash
git diff --stat HEAD:application/.../SysSubscriptionController.java 14021f1d
# 1 file changed, 294 insertions(+)   ← 纯新增 0 删除，恢复绝对安全
```

---

## 五、恢复操作

`git cat-file -p` 把 blob 内容重定向覆盖回文件即可：

```bash
git cat-file -p 14021f1d0a65... > application/.../admin/controller/SysSubscriptionController.java
git cat-file -p e814db973a15... > application/.../vo/SubscriptionVo.java
```

> ⚠️ 第一次只恢复了控制器，编译仍爆红在 `vo.setRenewalCount/setTotalPaidAmount`——因为 `SubscriptionVo.java`（**已跟踪文件**）同样被 reset 冲掉了新增的 `renewalCount`、`totalPaidAmount` 字段。它和控制器是同一次事故的「连带受害者」。教训：**已跟踪文件的改动会被 `reset --hard` 静默清除，要顺着编译错误把每一个连带文件都找回来**。

### 用编译做最终验证（evidence before assertions）

```bash
mvn clean compile -Dmaven.test.skip=true -Pappprod -pl ./application/mybill/mybill-service/ -am
# BUILD SUCCESS
```

编译通过，爆红消除，恢复完成。最后**立即提交**，避免再被 reset：

```bash
git add application/mybill/mybill-service
git commit -m "feat: 订阅明细增强-渠道与pay_order聚合"
```

---

## 六、根因与原理

### 6.1 `git reset` 三种模式对「index / 工作区」的影响

| 模式 | 移动 HEAD | 重置 index（暂存区） | 重置工作区 | 危险度 |
| --- | --- | --- | --- | --- |
| `--soft` | ✅ | ❌ | ❌ | 安全，改动留在暂存区 |
| `--mixed`（默认） | ✅ | ✅ | ❌ | 较安全，改动退回工作区 |
| `--hard` | ✅ | ✅ | ✅ | **危险，工作区改动直接丢弃** |

本次是 `--hard`：HEAD、暂存区、工作区三者全部对齐到 `origin/develop`，**已跟踪文件上一切未提交的改动被无声清除**。

### 6.2 为什么「新文件还在、改动消失」——未跟踪文件的特殊待遇

`git reset --hard` **只动 Git 已跟踪的文件**。未跟踪文件（untracked，`??`）不在 Git 的管理范围内，reset 一律不碰。这正好解释了割裂现象：

| 文件 | Git 视角 | `reset --hard` 后果 |
| --- | --- | --- |
| `SysSubscriptionController.java`（改） | 已跟踪 + 有未提交改动 | 改动被清除，回到 HEAD 版本 |
| `SubscriptionVo.java`（改） | 已跟踪 + 有未提交改动 | 同上，连带受害 |
| `SubscriptionDetailQueryDto.java`（新建） | 未跟踪 | **原样保留** |
| `util/ExcelExportUtil.java`（新建） | 未跟踪 | **原样保留** |

> 补充：要连未跟踪文件一起清掉，得另外执行 `git clean -fd`。所以「`reset --hard` + 没跑 `clean`」必然留下这种「新文件孤儿、调用代码消失」的指纹。

### 6.3 为什么改动能从 `.git/objects` 捞回——blob 何时进对象库

Git 的对象库在两种时机写入 blob：

1. **`git add`（暂存）时** —— 立刻为文件内容算 SHA-1 并写一个 blob 对象到 `.git/objects`
2. **`git commit` / `git stash`** —— 引用这些 blob 组成 tree、commit

本次的改动**虽然没 commit，但曾被 `git add` 过**（IDE 的 Git 集成或手动暂存），所以 blob 早已落盘。`reset --hard` 重置了 index 的指针，但**孤立的 blob 还在**，变成 dangling object，于是 `git fsck` 能找到、`git cat-file` 能读出。

### 6.4 ⚠️ 什么情况下捞不回

这是最关键的认知边界：

| 改动状态 | reset --hard 后能否用 git fsck 恢复 |
| --- | --- |
| 曾 `git add` 过（生成过 blob） | ✅ 能（本次情形） |
| 改了但**从未 add**（纯工作区改动） | ❌ **不能**，Git 从没见过它，对象库里没有 |
| 已 commit / stash | ✅ 能（reflog 或 stash list 都能找到，更直接） |

所以「从未 `git add` 的纯工作区改动」一旦被 `reset --hard` / `checkout --` / `clean` 清掉，Git 层面**无解**，只能靠：

- **IDE 的 Local History**（IDEA：文件右键 → Local History → Show History，与 Git 无关，按时间留快照）
- 编辑器本地缓存 / 系统备份

> 💡 这也是「**改一点就 `git add` 一次**」的隐藏价值：不光是为了 commit，暂存本身就是给对象库存一份可恢复的快照。

---

## 七、排查思路复盘

| 步骤 | 动作 | 结论 |
| --- | --- | --- |
| 1 | `git status --short` | 改动文件「消失」、新建文件仍在 → 怀疑 `reset --hard` |
| 2 | `git reflog` | `HEAD@{0}: reset: moving to origin/develop` 坐实案发点 |
| 3 | `git diff 旧 新` | 确认丢的不是 commit，而是「未提交改动」 |
| 4 | `git fsck --lost-found --no-reflogs` | 列出全部悬空 blob |
| 5 | 遍历 blob + `cat-file` + grep 特征类名 | 锁定 `14021f1d`(控制器) / `e814db97`(VO) |
| 6 | `git cat-file -p <blob> > 文件` | 还原；编译报错牵出连带受害的 VO，一并恢复 |
| 7 | `mvn compile` + `git commit` | 验证通过、立即落库防二次丢失 |

**心得三条**：

1. **代码"消失"先 `git reflog`，再 `git fsck`，最后才考虑重写**。Git 是有日志的系统，绝大多数「丢失」是「引用断了但对象还在」。
2. **`reset --hard` 的杀伤面 = 所有已跟踪文件的未提交改动**。看到「新文件还在、调用代码消失」的割裂，几乎就是它的指纹；要顺着编译错误把每个连带受害文件都找回来，别只修第一个报错点。
3. **能否恢复取决于「是否曾进入对象库」**。`git add` 过的能捞，纯工作区改动捞不回——这是平时勤 add / 勤 commit 最硬的理由。

---

## 八、预防

1. **改完一个小阶段就 `git add` + `git commit`**，哪怕是 WIP 提交。频繁提交 = 频繁存档，事故面最小。
2. **危险命令前先 `git stash` 或建临时分支兜底**：
   ```bash
   git stash               # 或
   git branch backup-wip   # 给当前 HEAD 打个标记，随时能回
   ```
3. **要同步远程，优先 `git pull --rebase` 而不是 `reset --hard origin/xxx`**。前者会保留/重放本地改动，后者直接丢弃。
4. **`reset --hard` 前确认工作区干净**：`git status` 有改动就先 stash/commit，别裸跑。
5. **依赖 IDE Local History 兜底**：IDEA 默认开启，纯工作区改动（连 Git 都救不了的）唯一退路就是它。
6. **团队层面**：约定「同步远程用 rebase / `reset --hard` 需二次确认」，写进 onboarding 文档。

---

## 九、相关 Git 数据恢复命令速查

| 场景 | 命令 |
| --- | --- |
| 看 HEAD 移动历史 | `git reflog` / `git reflog show <branch>` |
| 找回「误删的 commit」 | `git reflog` 找到哈希 → `git reset --hard <hash>` 或 `git cherry-pick <hash>` |
| 找回「误删分支」 | `git reflog` → `git branch <name> <hash>` |
| 列出所有悬空对象 | `git fsck --lost-found --no-reflogs` |
| 看悬空对象内容 / 类型 | `git cat-file -p <hash>` / `git cat-file -t <hash>` |
| 还原单个文件到某版本 | `git cat-file -p <blob> > file` 或 `git checkout <commit> -- <file>` |
| 找回 stash | `git stash list` → `git stash apply stash@{n}`；误 drop 的 stash 也能 `git fsck` 捞 |
| 误 `commit --amend` 找回原 commit | `git reflog` 里 amend 前的哈希仍在 |

---

## 十、参考

- [Maven 编译排查实录](Maven%20编译排查实录.md) — 同类风格的排障复盘
- [SLF4J 绑定排查实录](SLF4J%20绑定排查实录.md)
- Git 官方 reset 文档：[git-reset](https://git-scm.com/docs/git-reset)
- Git 数据恢复：[Pro Git — Data Recovery](https://git-scm.com/book/en/v2/Git-Internals-Maintenance-and-Data-Recovery)
- `git fsck` 文档：[git-fsck](https://git-scm.com/docs/git-fsck)
