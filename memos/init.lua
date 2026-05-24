local action = require 'memos.action'
local config = require 'memos.config'

local M = {}

function M.meta()
  return {
    icon = '󰎞',
    desc = 'Memos note client',
    color = 'yellow',
  }
end

local function memo_entry(memo)
  local content = memo.content or ''
  local display_parts = {}

  if memo.createTime then
    local success, parsed = pcall(deck.time.parse, memo.createTime)
    if success then
      memo.timestamp = parsed
      table.insert(display_parts, deck.time.format(memo.timestamp, 'compact'):fg 'yellow')
      table.insert(display_parts, ' ')
    end
  end

  local display_title = content:utf8_sub(1, 60)
  if #content > 60 then display_title = display_title .. '...' end
  table.insert(display_parts, display_title:fg 'green')

  return {
    key = tostring(memo.id),
    kind = 'memo',
    memo = memo,
    display = deck.style.line(display_parts),
  }
end

local function register_page_keymaps()
  local keymap = config.get().keymap or {}
  local path = '/memos/**'

  local function map(key, callback, desc)
    if key and key ~= '' then
      deck.keymap.set('main', key, callback, { path = path, desc = desc })
    end
  end

  map(keymap.new, action.create_new_memo, 'new memo')
  map(keymap.open, action.edit_current_memo, 'edit memo')
  map(keymap.edit, action.edit_current_memo, 'edit memo')
  map(keymap.copy, action.yank_current_memo, 'copy memo content')
  map(keymap.delete, action.delete_current_memo, 'delete memo')
end

function M.setup(opt)
  config.setup(opt or {})
  action.setup(config.get())
  register_page_keymaps()
end

function M.list(_, cb)
  deck.log('info', 'Loading memos list')
  deck.api.set_preview(nil, 'Loading memos...')

  if not action.ready() then
    cb({
      {
        key = 'configure',
        kind = 'info',
        selectable = false,
        title = 'memos',
        message = 'Configure memos token and base_url first',
        detail = 'Set them in setup() before using this plugin.',
        color = 'yellow',
      },
    })
    return
  end

  action.api_call('GET', '/memos?state=NORMAL&pageSize=100', nil, function(res)
    if not res.success then
      deck.notify('Error: ' .. tostring(res.error or 'Unknown error'))
      cb({})
      return
    end

    local memos = deck.json.decode(res.body)
    if type(memos) ~= 'table' or type(memos.memos) ~= 'table' or #memos.memos == 0 then
      deck.notify 'No memos found'
      cb({})
      return
    end

    local entries = {}
    for _, memo in ipairs(memos.memos) do
      memo.id = memo.name and memo.name:sub(7) or tostring(memo.id or '')
      table.insert(entries, memo_entry(memo))
    end

    deck.log('info', 'Loaded {} memos entries', #entries)
    cb(entries)
  end)
end

function M.preview(entry, cb)
  if not entry then
    cb(deck.style.text { deck.style.line { 'memos' } })
    return
  end

  if entry.kind == 'memo' then
    action.memo_preview(entry, cb)
    return
  end

  cb(action.info_preview(entry))
end

return M
