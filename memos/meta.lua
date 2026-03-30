local action = require 'memos.action'

local M = {}

local function add_keymap(targets, key, callback, desc)
  if not key or key == '' then return end
  for _, target in ipairs(targets) do
    target[key] = { callback = callback, desc = desc }
  end
end

local metas = {
  memo = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        action.memo_preview(entry, cb)
      end,
    },
  },
  info = {
    __index = {
      keymap = {},
      preview = function(entry, cb)
        cb(action.info_preview(entry))
      end,
    },
  },
}

function M.setup(cfg)
  local keymap = (cfg or {}).keymap or {}
  local memo_map = metas.memo.__index.keymap
  local info_map = metas.info.__index.keymap

  for _, map in ipairs({ memo_map, info_map }) do
    for key, _ in pairs(map) do
      map[key] = nil
    end
  end

  add_keymap({ memo_map, info_map }, keymap.new, action.create_new_memo, 'new memo')
  add_keymap({ memo_map }, keymap.open, action.edit_current_memo, 'edit memo')
  add_keymap({ memo_map }, keymap.edit, action.edit_current_memo, 'edit memo')
  add_keymap({ memo_map }, keymap.copy, action.yank_current_memo, 'copy memo content')
  add_keymap({ memo_map }, keymap.delete, action.delete_current_memo, 'delete memo')
end

function M.attach(entries)
  for i, entry in ipairs(entries or {}) do
    local mt = metas[entry.kind]
    if mt then entries[i] = setmetatable(entry, mt) end
  end
  return entries
end

return M
