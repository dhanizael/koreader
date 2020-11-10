local Device = require("device")

if not Device.isAndroid() and not Device.isEmulator() then
    return { disabled = true }
end

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local function pathOk(filename)
    local path, name = util.splitFilePathName(filename)
    if not Device:isValidPath(path) then -- isValidPath expects a trailing slash
        return false, T(_("Path \"%1\" isn't in a writable location."), path)
    elseif not util.pathExists(path:gsub("/$", "")) then -- pathExists expects no trailing slash
        return false, T(_("The path \"%1\" doesn't exist."), path)
    elseif name == "" then
        return false, _("Please enter a filename at the end of the path.")
    elseif lfs.attributes(filename, "mode") == "directory" then
        return false, T(_("The path \"%1\" must point to a file, but it points to a directory."), filename)
    end

    return true
end

local CoverImage = WidgetContainer:new{
    name = "coverimage",
    is_doc_only = true,
}

function CoverImage:init()
    self.cover_image_path = G_reader_settings:readSetting("cover_image_path") or "cover.png"
    self.cover_image_fallback_path = G_reader_settings:readSetting("cover_image_fallback_path") or "cover_fallback.png"
    self.enabled = G_reader_settings:isTrue("cover_image_enabled")
    self.fallback = G_reader_settings:isTrue("cover_image_fallback")
    self.ui.menu:registerToMainMenu(self)
end

function CoverImage:_enabled()
    return self.enabled
end

function CoverImage:_fallback()
    return self.fallback
end

function CoverImage:cleanUpImage()
    if self.cover_image_fallback_path == "" or not self.fallback then
        os.remove(self.cover_image_path)
    elseif lfs.attributes(self.cover_image_fallback_path, "mode") ~= "file" then
        UIManager:show(InfoMessage:new{
            text = T(_("\"%1\" \nis not a valid image file!\nA valid fallback image is required in Cover-Image"), self.cover_image_fallback_path),
            show_icon = true,
            timeout = 10,
        })
        os.remove(self.cover_image_path)
    elseif pathOk(self.cover_image_path) then
        ffiutil.copyFile(self.cover_image_fallback_path, self.cover_image_path)
    end
end

function CoverImage:createCoverImage(doc_settings)
   if self.enabled and not doc_settings:readSetting("exclude_cover_image") == true then
        local image = self.ui.document:getCoverPageImage()
        if image then
            image:writePNG(self.cover_image_path, false)
            logger.dbg("CoverImage: image written to " .. self.cover_image_path)
        end
    end
end

function CoverImage:onCloseDocument()
    logger.dbg("CoverImage: onCloseDocument")
    if self.fallback then
        self:cleanUpImage()
    end
end

function CoverImage:onReaderReady(doc_settings)
    logger.dbg("CoverImage: onReaderReady")
    self:createCoverImage(doc_settings)
end

local about_text = _([[
This plugin saves the current book cover to a file. That file can be used as a screensaver on certain Android devices, such as Tolinos.

If enabled, the cover image of the actual file is stored in the selected screensaver file. Books can be excluded if desired.

If fallback is activated, the fallback file will be copied to the screensaver file on book closing.
If the filename is empty or the file doesn't exist, the cover file will be deleted and the system screensaver will be used instead.

If the fallback image isn't activated, the screensaver image will stay in place after closing a book.]])

function CoverImage:addToMainMenu(menu_items)
    menu_items.coverimage = {
--        sorting_hint = "document",
        sorting_hint = "screen",
        text = _("Save cover image"),
        checked_func = function()
            return self.enabled or self.fallback
        end,
        sub_item_table = {
            -- menu entry: about cover image
            {
                text = _("About cover image"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = about_text,
                    })
                end,
                separator = true,
            },
            -- menu entry: filename dialog
            {
                text = _("Set system screensaver image"),
                checked_func = function()
                    return self.cover_image_path ~= "" and pathOk(self.cover_image_path)
                end,
                help_text = _("The cover of the current book will be stored in this file."),
                keep_menu_open = true,
                callback = function(menu)
                    local InputDialog = require("ui/widget/inputdialog")
                    local sample_input
                    sample_input = InputDialog:new{
                        title = _("Screensaver image filename"),
                        input = self.cover_image_path,
                        input_type = "string",
                        description = _("You can enter the filename of the cover image here."),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(sample_input)
                                    end,
                                },
                                {
                                    text = _("Save"),
                                    is_enter_default = true,
                                    callback = function()
                                        local new_cover_image_path = sample_input:getInputText()
                                        if new_cover_image_path ~= self.cover_image_path then
                                            self:cleanUpImage() -- with old filename
                                            self.cover_image_path = new_cover_image_path -- update filename
                                            G_reader_settings:saveSetting("cover_image_path", self.cover_image_path)
                                            local is_path_ok, is_path_ok_message = pathOk(self.cover_image_path)
                                            if self.cover_image_path ~= "" and is_path_ok then
                                                self:createCoverImage(self.ui.doc_settings) -- with new filename
                                            else
                                                self.enabled = false
                                                UIManager:show(InfoMessage:new{
                                                    text = is_path_ok_message,
                                                    show_icon = true,
                                                })
                                            end
                                        end
                                        UIManager:close(sample_input)
                                        menu:updateItems()
                                    end,
                                },
                            }
                        },
                    }
                    UIManager:show(sample_input)
                    sample_input:onShowKeyboard()
                end,
            },
            -- menu entry: enable
            {
                text = _("Save book cover"),
                checked_func = function()
                    return self:_enabled() and pathOk(self.cover_image_path)
                end,
                enabled_func = function()
                    return self.cover_image_path ~= "" and pathOk(self.cover_image_path)
                end,
                callback = function()
                    if self.cover_image_path ~= "" then
                        self.enabled = not self.enabled
                        G_reader_settings:saveSetting("cover_image_enabled", self.enabled)
                        if self.enabled then
                            self:createCoverImage(self.ui.doc_settings)
                        else
                            self:cleanUpImage()
                        end
                    end
                end,
            },
            -- menu entry: exclude this cover
            {
                text = _("Exclude this book cover"),
                checked_func = function()
                    return self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting("exclude_cover_image") == true
                end,
                callback = function()
                    if self.ui.doc_settings:readSetting("exclude_cover_image") == true then
                        self.ui.doc_settings:saveSetting("exclude_cover_image", false)
                        self:createCoverImage(self.ui.doc_settings)
                    else
                        self.ui.doc_settings:saveSetting("exclude_cover_image", true)
                        self:cleanUpImage()
                    end
                    self.ui:saveSettings()
                end,
                separator = true,
            },
            -- menu entry: set fallback image
            {
                text = _("Set fallback image"),
                checked_func = function()
                    return lfs.attributes(self.cover_image_fallback_path, "mode") == "file"
                end,
                help_text =  _("File to use when no cover is wanted (found ???) or book is excluded.\nLeave this blank to turn off the fallback image."),
                keep_menu_open = true,
                callback = function(menu)
                    local InputDialog = require("ui/widget/inputdialog")
                    local sample_input
                    sample_input = InputDialog:new{
                        title = _("Fallback image filename"),
                        input = self.cover_image_fallback_path,
                        input_type = "string",
                        description = _("Leave this empty to remove the cover when the document is closed."),
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(sample_input)
                                    end,
                                },
                                {
                                    text = _("Save"),
                                    is_enter_default = true,
                                    callback = function()
                                        self.cover_image_fallback_path = sample_input:getInputText()
                                        G_reader_settings:saveSetting("cover_image_fallback_path", self.cover_image_fallback_path)
                                        if lfs.attributes(self.cover_image_fallback_path, "mode") ~= "file" then
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("\"%1\" \nis not a valid image file!\nA valid fallback image is required in Cover-Image"),
                                                    self.cover_image_fallback_path),
                                                show_icon = true,
                                                timeout = 10,
                                            })
                                        end
                                        UIManager:close(sample_input)
                                        menu:updateItems()
                                    end,
                                },
                            }
                        },
                    }
                    UIManager:show(sample_input)
                    sample_input:onShowKeyboard()
                end,
            },
            -- menu entry: fallback
            {
                text = _("Turn on fallback image"),
                checked_func = function()
                    return self:_fallback()
                end,
                callback = function()
                    self.fallback = not self.fallback
                    G_reader_settings:saveSetting("cover_image_fallback", self.fallback)
                end,
                separator = true,
            },
        },
    }
end

return CoverImage
