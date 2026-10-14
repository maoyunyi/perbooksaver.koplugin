# PerBookSaver（本书屏保）

**给 KOReader 的每一本书单独指定待机屏保；没有单独设置的书，一律沿用全局屏保。**

[English](README.md) · **中文**

---

## 这是什么

KOReader 自带一套全局屏保（睡眠时显示什么）。本插件在它之上加了一层**按书覆盖**：

- 你可以让这本漫画待机时显示它自己的封面，那本小说显示你指定的图片，另一本随机轮播一个文件夹里的图；
- 没有单独设置的书，行为和你以前完全一样 —— 用全局屏保；
- 官方的全局屏保菜单**原封不动**保留，插件不会改动你已有的全局设置。

## 模式一览

| 菜单项 | 这本书待机时 |
| --- | --- |
| 跟随全局设置（当前：xx） | 清除本书设置，回到全局屏保 |
| 使用本书封面 | 显示这本书自己的封面 |
| 使用指定图片… | 显示你选的那一张图片（png / jpg 等） |
| 使用图片文件夹（随机）… | 从你选的文件夹里随机挑一张 |
| 保持屏幕原样（不使用屏保） | 什么也不画，保持进入待机前的那一屏 |

五个模式互斥，随时切换。**改本书设置不会动到全局设置。**

## 环境要求

- KOReader。本插件在 **v2026.07.1（Kindle Paperwhite 6）** 上实测通过。
- 只使用 KOReader 长期稳定的公开接口（`Screensaver:setup`、`LuaSettings`、菜单 API），
  Kobo / Android / 桌面版理论上同样可用，但未实测。

## 安装

1. 下载或克隆本仓库。插件本体就是其中的 `perbooksaver.koplugin` 文件夹 ——
   **目录名必须以 `.koplugin` 结尾**，否则 KOReader 不会加载它。
2. 把整个文件夹复制进 KOReader 的插件目录：

   | 平台 | 插件目录 |
   | --- | --- |
   | Kindle | `/mnt/us/koreader/plugins/` |
   | Kobo | `.adds/koreader/plugins/` |
   | 其他 | KOReader 数据目录下的 `plugins/` |

3. **重启 KOReader**：文件管理器 → 顶部菜单 → 「退出」组 → 「重启 KOReader」。

也可以在终端里做完（把仓库地址换成你自己的）：

```bash
git clone --depth 1 https://github.com/<your-name>/<your-repo>.git /tmp/perbooksaver
cp -r /tmp/perbooksaver/perbooksaver.koplugin <koreader数据目录>/plugins/
rm -rf /tmp/perbooksaver
```

## 使用方法

打开任意一本书 → **设置 → 屏保**。面板**最上面一组**就是「本书屏保（书名）」：

| 菜单项 | 说明 |
| --- | --- |
| 当前书籍：xxx | 点一下弹出规则说明；顺便确认设置作用于哪本书 |
| 跟随全局设置（当前：xx） | 清除本书设置，这本书恢复用全局屏保 |
| 使用本书封面 | 本书待机时显示自己的封面 |
| 使用指定图片… | 选一张图片，本书待机时显示它 |
| 使用图片文件夹（随机）… | 选一个文件夹，本书待机时随机显示其中图片 |
| 保持屏幕原样（不使用屏保） | 等同官方同名选项：本书待机时什么也不画 |
| 清除所有书籍的屏保设置 | 一键删掉全部单独设置 |

这一组在**文件管理器**里也会出现（标题不带书名），此时它作用于你最近打开的那本书。
阅读界面里打开同一本书，才是精确指到当前这本。

## 优先级规则

1. 这本书有单独设置 → 用这本书的；
2. 这本书没有设置 → 用全局；
3. 本书设置的图片 / 文件夹被删掉或访问不到 → 自动回落全局，并往 `crash.log` 写一条 warn；
4. **睡眠、关机、重启**三种触发都套用同一套规则；
5. 例外：如果你在官方菜单里显式设过「关机专用屏保」，关机时仍以那个为准（官方行为原样保留）。

不覆盖「呈现方式」类选项（更新延迟、屏保文字、背景填充、拉伸 / 旋转），它们仍然走全局。

## 配置文件

配置存在 KOReader 设置目录下的 `perbook_screensaver.json`，插件独占读写，
**不写进书自己的 sidecar（`.sdr`）**，所以拷贝 / 同步书籍时不会把你的屏保设置一起带走。

```json
{
  "version": 1,
  "books": {
    "/mnt/us/koreader/manga/xxx.cbz": { "kind": "cover" },
    "/mnt/us/koreader/books/a.epub":  { "kind": "image", "path": "/mnt/us/screensaver/bg.png" },
    "/mnt/us/koreader/manga/m2/":     { "kind": "folder", "path": "/mnt/us/screensaver/manga" },
    "/mnt/us/koreader/books/b.epub":  { "kind": "disable" }
  }
}
```

键是书籍的绝对路径，`kind` 取 `cover` / `image` / `folder` / `disable`
（`disable` 表示保持屏幕原样，不需要 `path`）。

## 常见问题

- **菜单里没有「本书屏保」** —— 确认目录名以 `.koplugin` 结尾并已重启 KOReader；
  再到 设置 → 工具 → 插件管理 看插件是否被停用。
- **设置了但待机没变化** —— 在 `crash.log` 里搜 `PerBookSaver`。资源不可用会打 warn 并回落全局。
- **会改到我的全局屏保设置吗** —— 不会。详见下面的「工作原理」。
- **切换模式要重启吗** —— 不用，选完立即生效。
- **这本书有 `exclude_screensaver` 标记会怎样** —— 那是 KOReader 自己的文档级设置，官方会把它和
  「保持屏幕原样」相互作用，插件不干预这条官方逻辑。

## 卸载

删掉 `plugins/perbooksaver.koplugin/` 目录并重启 KOReader。
残留的 `settings/perbook_screensaver.json` 可以一并删掉（留着也无害）。

## 工作原理

全流程读取屏保设置的地方只有一处：`frontend/ui/screensaver.lua` 里的
`Screensaver:setup(event, event_message)`。插件只在这一处外面包了一层：

```
保存全局真值 → 临时写入这本书的值 → pcall(原 setup) → 立刻还原全局真值（出错也还原）
```

这段替换不跨越任何 UI 事件循环，所以 **磁盘上的全局设置从头到尾没被改过** ——
随时断电、进程被系统 kill 都不会残留脏值，也不需要任何跨进程的内存状态。

对比之下，"打开书时把本书的值直接写进全局、靠内存变量记账还原" 那类做法，一旦进程被 kill
就会把全局值永久改坏，而且记账变量重启即失忆。本插件刻意避开了这条路。

## License

本项目采用 [MIT 许可证](LICENSE) © 2026 m40kao。
