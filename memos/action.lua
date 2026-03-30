local M = {}

local cfg = nil

local function trim_or_empty(value)
  return tostring(value or ''):match '^%s*(.-)%s*$'
end

local function create_temp_file(prefix, suffix)
  local timestamp = os.time()
  return '/tmp/' .. prefix .. '_' .. timestamp .. suffix
end

local function current_entry()
  local entry = lc.api.page_get_hovered()
  if not entry or entry.kind ~= 'memo' or not entry.memo then return nil end
  return entry
end

local function format_timestamp(ts)
  if not ts then return 'Unknown' end
  local success, timestamp = pcall(lc.time.parse, ts)
  if success and timestamp then return os.date('%Y-%m-%d %H:%M:%S', timestamp) end
  return ts
end

function M.setup(opt)
  cfg = opt
end

function M.ready()
  return cfg and trim_or_empty(cfg.token) ~= '' and trim_or_empty(cfg.base_url) ~= ''
end

function M.api_call(method, path, body, cb)
  lc.log('debug', 'API call: {} {}', method, path)

  lc.http.request({
    method = method,
    url = cfg.base_url .. '/api/v1' .. path,
    headers = {
      ['Authorization'] = 'Bearer ' .. cfg.token,
      ['Content-Type'] = 'application/json',
    },
    body = body and lc.json.encode(body),
  }, function(response) cb(response) end)
end

function M.edit_current_memo(entry)
  entry = entry or current_entry()
  if not entry then
    lc.notify 'No memo selected'
    return
  end

  local memo = entry.memo
  local temp_file = create_temp_file('memo', '.md')
  local content = memo.content or ''
  local success, err = lc.fs.write_file_sync(temp_file, content)
  if not success then
    lc.notify('Failed to create temp file: ' .. tostring(err or 'Unknown error'))
    return
  end

  lc.interactive({ cfg.editor, temp_file }, function()
    local new_content, read_err = lc.fs.read_file_sync(temp_file)
    if not new_content then
      lc.notify('Error: Failed to read edited content ' .. tostring(read_err or ''))
      return
    end

    if new_content == content then
      lc.notify 'No changes made'
      return
    end

    M.api_call('PATCH', '/memos/' .. memo.id, {
      content = new_content,
    }, function(res)
      if not res.success then
        lc.notify('Failed to update memo: ' .. tostring(res.error or 'Unknown error'))
        return
      end

      lc.notify 'Memo updated successfully'
      lc.cmd 'reload'
    end)

    os.remove(temp_file)
  end)
end

function M.yank_current_memo(entry)
  entry = entry or current_entry()
  if not entry or not entry.memo.content then
    lc.notify 'No memo selected'
    return
  end

  local success, err = pcall(lc.osc52_copy, entry.memo.content:trim())
  if not success then
    lc.notify('Failed to copy: ' .. tostring(err))
    return
  end
  lc.notify 'Copied to clipboard'
end

function M.delete_current_memo(entry)
  entry = entry or current_entry()
  if not entry then
    lc.notify 'No memo selected'
    return
  end

  lc.confirm {
    prompt = 'Delete this memo?',
    on_confirm = function()
      M.api_call('DELETE', '/memos/' .. entry.memo.id, nil, function(res)
        if not res.success then
          lc.notify('Failed to delete memo: ' .. tostring(res.error or 'Unknown error'))
          return
        end

        lc.notify('Memo deleted successfully: ' .. entry.memo.id)
        lc.cmd 'reload'
      end)
    end,
  }
end

function M.create_new_memo()
  local temp_file = create_temp_file('new_memo', '.md')
  lc.fs.write_file_sync(temp_file, '')

  lc.interactive({ cfg.editor, temp_file }, function()
    local content, err = lc.fs.read_file_sync(temp_file)
    os.remove(temp_file)
    if err then
      lc.notify('Error: Failed to read edited content' .. err)
      return
    end
    if not content then
      lc.notify 'Failed to read edited content'
      return
    end
    if content:match '^%s*$' then
      lc.notify 'No content provided'
      return
    end

    M.api_call('POST', '/memos', {
      content = content,
      visibility = cfg.visibility,
    }, function(res)
      if not res.success then
        lc.notify('Failed to create memo: ' .. tostring(res.error or 'Unknown error'))
        return
      end

      local result = lc.json.decode(res.body)
      if result and result.name then
        lc.notify('Memo created: ' .. result.name)
      else
        lc.notify 'Memo created successfully'
      end

      lc.cmd 'reload'
      lc.cmd 'scroll_by -9999'
    end)
  end)
end

function M.build_preview(memo)
  local lines = {}
  table.insert(lines, lc.style.line { ('[memo] '):fg 'cyan', ('Metadata'):fg 'cyan' })
  table.insert(lines, lc.style.line { ('   ID:           '):fg 'cyan', (memo.id or ''):fg 'yellow' })
  table.insert(lines, lc.style.line { ('   State:        '):fg 'cyan', (memo.state or 'UNKNOWN'):fg 'blue' })
  table.insert(lines, lc.style.line { ('   Visibility:   '):fg 'cyan', (memo.visibility or 'PRIVATE'):fg 'magenta' })
  table.insert(lines, lc.style.line { ('   Created:      '):fg 'cyan', format_timestamp(memo.createTime):fg 'green' })
  table.insert(lines, lc.style.line { ('   Updated:      '):fg 'cyan', format_timestamp(memo.updateTime):fg 'green' })

  if memo.pinned then table.insert(lines, lc.style.line { ('   '):fg 'cyan', ('Pinned'):fg 'yellow' }) end

  if memo.tags and #memo.tags > 0 then
    local tag_parts = {}
    table.insert(tag_parts, ('   Tags:         '):fg 'cyan')
    for i, tag in ipairs(memo.tags) do
      if i > 1 then table.insert(tag_parts, ' ') end
      table.insert(tag_parts, ('#' .. tag):fg 'cyan')
    end
    table.insert(lines, lc.style.line(tag_parts))
  else
    table.insert(lines, lc.style.line { ('   Tags:         '):fg 'cyan', ('(none)'):fg 'dark_gray' })
  end

  if memo.attachments and #memo.attachments > 0 then
    table.insert(lines, lc.style.line {
      ('   '):fg 'cyan',
      ('Attachments: '):fg 'cyan',
      tostring(#memo.attachments):fg 'yellow',
    })
  end

  if memo.relations and #memo.relations > 0 then
    table.insert(lines, lc.style.line {
      ('   '):fg 'cyan',
      ('Relations:   '):fg 'cyan',
      tostring(#memo.relations):fg 'blue',
    })
  end

  if memo.reactions and #memo.reactions > 0 then
    table.insert(lines, lc.style.line {
      ('   '):fg 'cyan',
      ('Reactions:  '):fg 'cyan',
      tostring(#memo.reactions):fg 'red',
    })
  end

  table.insert(lines, '')
  table.insert(lines, lc.style.line { ('[cfg] '):fg 'cyan', ('Properties'):fg 'cyan' })
  if memo.property then
    local props = {}
    if memo.property.hasLink then table.insert(props, ('links'):fg 'blue') end
    if memo.property.hasTaskList then table.insert(props, ('tasks'):fg 'green') end
    if memo.property.hasCode then table.insert(props, ('code'):fg 'magenta') end
    if memo.property.hasIncompleteTasks then table.insert(props, ('incomplete_tasks'):fg 'yellow') end
    if #props > 0 then
      local prop_parts = { '   ' }
      for i, prop in ipairs(props) do
        if i > 1 then table.insert(prop_parts, ', ') end
        table.insert(prop_parts, prop)
      end
      table.insert(lines, lc.style.line(prop_parts))
    else
      table.insert(lines, lc.style.line { ('   (none)'):fg 'dark_gray' })
    end
  else
    table.insert(lines, lc.style.line { ('   (none)'):fg 'dark_gray' })
  end

  table.insert(lines, '')
  table.insert(lines, lc.style.line { ('[txt] '):fg 'cyan', ('Content'):fg 'cyan' })
  table.insert(lines, '')
  table.insert(lines, memo.content or '(no content)')

  return lc.style.text(lines)
end

function M.memo_preview(entry, cb) cb(M.build_preview(entry.memo)) end

function M.info_preview(entry)
  return lc.style.text {
    lc.style.line { (entry.title or 'memos'):fg 'cyan' },
    lc.style.line { (entry.message or ''):fg(entry.color or 'darkgray') },
    lc.style.line { (entry.detail or ''):fg 'darkgray' },
  }
end

return M
