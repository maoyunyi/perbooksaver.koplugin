--[[
 * KOReader 插件 · AutoScreensaver —— 逐本书待机屏保   v1.1.0
 *
 * 【功能】
 *   在官方「睡眠屏保」体系之上，为单本书指定屏保图片。没有单独设置的书籍一律使用
 *   全局屏保。官方那套全局菜单元封不动保留，本插件不改动它的行为。
 *
 * 【为什么不沿用旧版的"临时改写全局"做法】
 *   旧版在打开/睡眠时把某本书的设置直接写进全局 screensaver_type，再靠内存变量记账
 *   还原。问题是：进程被系统 kill（KOReader 在 Kindle 上太常见了）或崩溃时，全局值就
 *   永久残留成某本书的值；而内存记账变量重启即失忆，再次启动时还可能把"被覆盖的值"
 *   误认成用户真实全局 —— 越用越乱。
 *
 *   本版把拦截点收拢到一处：只包一层 Screensaver.setup()，在调用原函数前后做
 *   "作用域内替换"：
 *       保存真值 → 写入本书值 → 调用原 setup() → 立刻还原真值
 *   整个过程不跨越任何 UI 事件循环，LuaSettings 的磁盘 flush 不可能插进来，
 *   所以全局设置在磁盘上从未被改动过，随时断电都不会残留，也不需要任何内存状态。
 *   若 setup() 抛错，仍会先还原再抛出。
 *
 * 【拦截点（已按设备上的 v2026.07.1 源码逐行核对）】
 *   frontend/ui/screensaver.lua 的 Screensaver:setup(event, event_message) 是全流程
 *   唯一读取 screensaver_type 的地方（line 354）。睡眠由
 *   frontend/device/kindle/device.lua:758 触发，关机/重启由
 *   frontend/ui/uimanager.lua:78/96 触发 —— 都汇流到同一个 setup()。
 *
 * 【覆盖范围与优先级】
 *   - 本书有设置 → 用本书的；本书没有 → 用全局（不发明额外的"默认"概念）。
 *   - 只覆盖"显示什么"：
 *       本书封面     → screensaver_type = "cover"（官方即取当前书 lastfile 的封面）
 *       指定图片     → screensaver_type = "document_cover" + screensaver_document_cover
 *       图片文件夹   → screensaver_type = "random_image"    + screensaver_dir
 *       保持屏幕原样 → screensaver_type = "disable"（官方同名选项：待机时不画屏保）
 *   - 不碰 screensaver_delay / 消息文字 / 背景填充 / 拉伸等"呈现方式"选项，它们走全局。
 *   - 不碰官方给关机/重启预留的 poweroff_ / reboot_ 前缀键，所以你显式设过的
 *     「关机专用屏保」依然是那边优先（官方行为原样保留，关机提示文字也不会消失）。
 *   - 每本书设置的图片/文件夹如果被删除或不可访问，自动回退全局（并写日志），不会报错。
 *
 * 【存储】
 *   KOReader 设置目录下的 perbook_screensaver.json，插件独占读写，不碰 DocSettings，
 *   避免与 KOReader 自身的 sidecar 句柄竞争：
 *     { "version": 1,
 *       "books": { "<书籍绝对路径>": { "kind": "cover|image|folder|disable", "path": "…" } } }
 *   kind = "disable" 时不需要 path（表示这本书不使用屏保）。
 *   键取 G_reader_settings 的 lastfile —— 和官方 cover 模式取书的方式完全一致，
 *   因此阅读界面与文件管理器里指向的是同一本书。
 *
 * 【安装】
 *   目录名必须以 .koplugin 结尾：
 *     /mnt/us/koreader/plugins/autoscreensaver.koplugin/{main.lua,_meta.lua}
 *   放好后重启 KOReader。菜单入口：设置 → 屏保（睡眠屏保）面板内的第一项。
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local AutoScreensaver = WidgetContainer:extend{
    name = "AutoScreensaver",
    is_doc_only = false,
}

local STORE_FILE = "perbook_screensaver.json"
local STORE_VERSION = 1
local GROUP_MARK = "autoscreensaver_group"
local PATCH_MARK = "_autoscreensaver_patched"

-- ===========================================================================
-- 小工具
-- ===========================================================================

-- 按 UTF-8 边界安全截断，用于把长文件名塞进菜单行
local function shorten(text, max_bytes)
    if type(text) ~= "string" or #text <= max_bytes then
        return text
    end
    local cut = max_bytes
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then
            break -- 落在字符首字节（或结尾），可以安全切
        end
        cut = cut - 1
    end
    if cut <= 0 then return text end
    return text:sub(1, cut) .. "…"
end

local function basename(path)
    if type(path) ~= "string" then return nil end
    return path:match("([^/]+)$") or path
end

-- 当前书 = KOReader 记的 lastfile，与官方 cover 模式取书方式一致
local function current_book_path()
    local path = G_reader_settings and G_reader_settings:readSetting("lastfile")
    if type(path) == "string" and path ~= "" then
        return path
    end
    return nil
end

-- ===========================================================================
-- 配置存储（插件独占的 JSON 文件）
-- ===========================================================================

local Store = {}

local function store_path()
    return DataStorage:getSettingsDir() .. "/" .. STORE_FILE
end

local function read_store()
    local db = { version = STORE_VERSION, books = {} }
    local file = io.open(store_path(), "r")
    if not file then return db end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then return db end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" and type(data.books) == "table" then
        db.books = data.books
    elseif not ok then
        logger.warn("AutoScreensaver: 无法解析配置，已按空配置处理：", store_path())
    end
    return db
end

local function write_store(db)
    local ok, encoded = pcall(json.encode, db)
    if not ok or type(encoded) ~= "string" then
        logger.warn("AutoScreensaver: 配置序列化失败")
        return false
    end
    local file = io.open(store_path(), "w")
    if not file then
        logger.warn("AutoScreensaver: 配置写入失败：", store_path())
        return false
    end
    file:write(encoded)
    file:close()
    return true
end

function Store.get(path)
    if not path then return nil end
    local entry = read_store().books[path]
    if type(entry) == "table" and type(entry.kind) == "string" then
        return entry
    end
    return nil
end

function Store.set(path, entry)
    if not path or type(entry) ~= "table" then return false end
    local db = read_store()
    db.books[path] = entry
    return write_store(db)
end

function Store.clear(path)
    if not path then return false end
    local db = read_store()
    if db.books[path] == nil then return true end
    db.books[path] = nil
    return write_store(db)
end

function Store.count()
    local n = 0
    for _ in pairs(read_store().books) do n = n + 1 end
    return n
end

function Store.clear_all()
    return write_store({ version = STORE_VERSION, books = {} })
end

-- ===========================================================================
-- 覆盖逻辑
-- ===========================================================================

local function entry_is_usable(entry)
    if entry.kind == "cover" or entry.kind == "disable" then
        return true
    end
    if type(entry.path) ~= "string" or entry.path == "" then
        return false
    end
    if entry.kind == "image" then
        return lfs.attributes(entry.path, "mode") == "file"
    end
    if entry.kind == "folder" then
        return lfs.attributes(entry.path, "mode") == "directory"
    end
    return false
end

-- 把某本书的配置翻译成「需要临时替换的 settings 键值」
local function overrides_for(entry)
    if entry.kind == "cover" then
        return { screensaver_type = "cover" }
    end
    if entry.kind == "disable" then
        return { screensaver_type = "disable" }
    end
    if entry.kind == "image" then
        return {
            screensaver_type = "document_cover",
            screensaver_document_cover = entry.path,
        }
    end
    if entry.kind == "folder" then
        return {
            screensaver_type = "random_image",
            screensaver_dir = entry.path,
        }
    end
    return nil
end

-- 当前这本书要用的覆盖项；没有 / 不可用 → nil（即走全局）
local function active_overrides()
    local path = current_book_path()
    if not path then return nil end
    local entry = Store.get(path)
    if not entry then return nil end
    if not entry_is_usable(entry) then
        logger.warn("AutoScreensaver: 本书屏保资源不可用，回退全局：", path, entry.kind, entry.path)
        return nil
    end
    return overrides_for(entry)
end

local function swap_in(overrides)
    if not overrides then return nil end
    local saved = {}
    for key, value in pairs(overrides) do
        saved[key] = {
            existed = G_reader_settings:has(key),
            value = G_reader_settings:readSetting(key),
        }
        G_reader_settings:saveSetting(key, value)
    end
    return saved
end

local function restore_all(saved)
    for key, old in pairs(saved) do
        if old.existed then
            G_reader_settings:saveSetting(key, old.value)
        else
            G_reader_settings:delSetting(key)
        end
    end
end

local function install_patch()
    if Screensaver[PATCH_MARK] then return end
    if type(Screensaver.setup) ~= "function" then
        logger.warn("AutoScreensaver: 找不到 Screensaver.setup()，插件未生效")
        return
    end
    Screensaver[PATCH_MARK] = true

    local orig_setup = Screensaver.setup
    Screensaver.setup = function(self, event, event_message)
        local saved
        local ok_swap, swap_err = pcall(function()
            saved = swap_in(active_overrides())
        end)
        if not ok_swap then
            logger.warn("AutoScreensaver: 应用本书屏保失败，改用全局设置：", swap_err)
            saved = nil
        end

        local ok, err = pcall(orig_setup, self, event, event_message)

        if saved then
            local ok_restore, restore_err = pcall(restore_all, saved)
            if not ok_restore then
                logger.warn("AutoScreensaver: 还原全局设置失败：", restore_err)
            end
        end

        if not ok then
            error(err, 0)
        end
    end
end

-- ===========================================================================
-- 菜单
-- ===========================================================================

local GLOBAL_TYPE_NAMES = {
    cover           = _("书籍封面"),
    document_cover  = _("自定义图片"),
    random_image    = _("随机图片"),
    readingprogress = _("阅读进度"),
    bookstatus     = _("书籍状态"),
    disable         = _("保持屏幕原样"),
    message         = _("消息"),
}

local function global_type_text()
    local kind = G_reader_settings:readSetting("screensaver_type")
    return GLOBAL_TYPE_NAMES[kind] or tostring(kind or "?")
end

local function entry_text(entry)
    if not entry then return _("跟随全局") end
    if entry.kind == "cover" then return _("本书封面") end
    if entry.kind == "disable" then return _("保持屏幕原样") end
    if type(entry.path) == "string" then
        return shorten(basename(entry.path), 30)
    end
    if entry.kind == "image" then return _("指定图片") end
    return _("图片文件夹")
end

local function refresh_menu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.updateItems then
        pcall(touchmenu_instance.updateItems, touchmenu_instance)
    end
end

local function choose_image(current_path, on_done)
    filemanagerutil.showChooseDialog(
        _("选择本书的屏保图片"),
        function(path) on_done(path) end,
        current_path,
        nil,
        function(filename) return DocumentRegistry:isImageFile(filename) end,
        true -- 提供「重置」按钮：清掉本书设置，回到跟随全局
    )
end

local function choose_folder(current_path, on_done)
    filemanagerutil.showChooseDialog(
        _("选择本书的随机图片文件夹"),
        function(path) on_done(path) end,
        current_path,
        nil,
        nil, -- 无 file_filter 即为「选文件夹」模式
        true
    )
end

local function show_help()
    UIManager:show(InfoMessage:new{
        text = _([[
本书屏保的规则：

· 本书有单独设置 → 待机时用本书的；
· 本书没有设置 → 用全局屏保。

改本书设置不会改动全局设置，也不会写进书的 sidecar 文件。
睡眠、关机、重启三种触发都适用。

设置保存在 KOReader 设置目录的 perbook_screensaver.json。]]),
        timeout = 20,
    })
end

local function build_group_items()
    local items = {
        {
            text_func = function()
                local name = basename(current_book_path())
                if name then
                    return T(_("当前书籍：%1"), shorten(name, 34))
                end
                return _("当前没有打开的书")
            end,
            keep_menu_open = true,
            callback = show_help,
        },
        {
            text_func = function()
                return T(_("跟随全局设置（当前：%1）"), global_type_text())
            end,
            enabled_func = function() return current_book_path() ~= nil end,
            checked_func = function()
                return current_book_path() ~= nil and Store.get(current_book_path()) == nil
            end,
            keep_menu_open = true,
            radio = true,
            callback = function(touchmenu_instance)
                Store.clear(current_book_path())
                refresh_menu(touchmenu_instance)
            end,
        },
        {
            text = _("使用本书封面"),
            enabled_func = function() return current_book_path() ~= nil end,
            checked_func = function()
                local entry = Store.get(current_book_path())
                return entry ~= nil and entry.kind == "cover"
            end,
            keep_menu_open = true,
            radio = true,
            callback = function(touchmenu_instance)
                Store.set(current_book_path(), { kind = "cover" })
                refresh_menu(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                local entry = Store.get(current_book_path())
                if entry and entry.kind == "image" then
                    return T(_("使用指定图片…（%1）"), entry_text(entry))
                end
                return _("使用指定图片…")
            end,
            help_text = _("选一张图片（png/jpg 等），本书待机时显示它。"),
            enabled_func = function() return current_book_path() ~= nil end,
            checked_func = function()
                local entry = Store.get(current_book_path())
                return entry ~= nil and entry.kind == "image"
            end,
            keep_menu_open = true,
            radio = true,
            callback = function(touchmenu_instance)
                local book = current_book_path()
                if not book then return end
                local entry = Store.get(book)
                choose_image(entry and entry.kind == "image" and entry.path or nil, function(path)
                    if path then
                        Store.set(book, { kind = "image", path = path })
                    else
                        Store.clear(book) -- 点了「重置」
                    end
                    refresh_menu(touchmenu_instance)
                end)
            end,
        },
        {
            text_func = function()
                local entry = Store.get(current_book_path())
                if entry and entry.kind == "folder" then
                    return T(_("使用图片文件夹（随机）…（%1）"), entry_text(entry))
                end
                return _("使用图片文件夹（随机）…")
            end,
            help_text = _("指定一个文件夹，本书待机时随机显示其中的图片。"),
            enabled_func = function() return current_book_path() ~= nil end,
            checked_func = function()
                local entry = Store.get(current_book_path())
                return entry ~= nil and entry.kind == "folder"
            end,
            keep_menu_open = true,
            radio = true,
            callback = function(touchmenu_instance)
                local book = current_book_path()
                if not book then return end
                local entry = Store.get(book)
                choose_folder(entry and entry.kind == "folder" and entry.path or nil, function(path)
                    if path then
                        Store.set(book, { kind = "folder", path = path })
                    else
                        Store.clear(book)
                    end
                    refresh_menu(touchmenu_instance)
                end)
            end,
        },
        {
            text = _("保持屏幕原样（不使用屏保）"),
            help_text = _("等同官方的「保持屏幕原样」：本书待机时什么也不画，保持进入待机前的那一屏。"),
            enabled_func = function() return current_book_path() ~= nil end,
            checked_func = function()
                local entry = Store.get(current_book_path())
                return entry ~= nil and entry.kind == "disable"
            end,
            keep_menu_open = true,
            radio = true,
            separator = true,
            callback = function(touchmenu_instance)
                local book = current_book_path()
                if not book then return end
                Store.set(book, { kind = "disable" })
                refresh_menu(touchmenu_instance)
            end,
        },
        {
            text = _("清除所有书籍的屏保设置"),
            help_text = _("删除全部单独设置，之后所有书籍都使用全局屏保。"),
            enabled_func = function() return Store.count() > 0 end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local count = Store.count()
                UIManager:show(ConfirmBox:new{
                    text = T(_("将删除 %1 本书的单独屏保设置，确定吗？"), count),
                    ok_text = _("删除"),
                    ok_callback = function()
                        Store.clear_all()
                        refresh_menu(touchmenu_instance)
                    end,
                })
            end,
        },
    }
    return items
end

local function make_group()
    return {
        text = _("本书屏保"),
        text_func = function()
            local name = basename(current_book_path())
            if name then
                return T(_("本书屏保（%1）"), shorten(name, 34))
            end
            return _("本书屏保")
        end,
        help_text = _("为当前这本书单独指定待机屏保；没有单独设置的书籍使用全局屏保。"),
        sub_item_table = build_group_items(),
        [GROUP_MARK] = true,
    }
end

-- ===========================================================================
-- 插件入口
-- ===========================================================================

function AutoScreensaver:init()
    -- 拦截 Screensaver:setup()，尽早装上，避免首次睡眠时还没生效
    install_patch()

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        local ok, err = pcall(self.ui.menu.registerToMainMenu, self.ui.menu, self)
        if not ok then
            logger.warn("AutoScreensaver: 菜单注册失败：", err)
        end
    end
end

function AutoScreensaver:addToMainMenu(menu_items)
    local screensaver = menu_items and menu_items.screensaver
    if type(screensaver) ~= "table" then return end

    local function inject(sub)
        if type(sub) ~= "table" then return end
        for _, item in ipairs(sub) do
            if type(item) == "table" and item[GROUP_MARK] then
                return -- 已经注入过
            end
        end
        -- 放在面板最前面：打开「屏保」第一眼就是本书的设置
        table.insert(sub, 1, make_group())
    end

    if type(screensaver.sub_item_table) == "table" then
        inject(screensaver.sub_item_table)
    elseif type(screensaver.sub_item_table_func) == "function" then
        -- 兼容将来改成函数式生成的版本
        local orig_func = screensaver.sub_item_table_func
        screensaver.sub_item_table_func = function()
            local sub = orig_func()
            inject(sub)
            return sub
        end
    end
end

return AutoScreensaver
