local M = {}

local config = {
  token = '',
  base_url = '',
  editor = os.getenv 'EDITOR' or 'vim',
  visibility = 'PRIVATE',
}

local function api_call(method, path, body, cb)
  lc.log('debug', 'API call: {} {}', method, path)

  lc.http.request({
    method = method,
    url = config.base_url .. '/api/v1' .. path,
    headers = {
      ['Authorization'] = 'Bearer ' .. config.token,
      ['Content-Type'] = 'application/json',
    },
    body = body and lc.json.encode(body),
  }, function(response) cb(response) end)
end

-- Create a temporary file for editing
local function create_temp_file(prefix, suffix)
  local timestamp = os.time()
  local tmp_path = '/tmp/' .. prefix .. '_' .. timestamp .. suffix
  return tmp_path
end

-- Edit the currently selected memo
local function edit_current_memo()
  local entry = lc.api.page_get_hovered()

  if not entry or not entry.memo then
    lc.notify 'No memo selected'
    lc.log('warn', 'No memo selected for editing')
    return
  end

  local memo = entry.memo

  lc.log('info', 'Editing memo #{}', memo.id)

  -- Create temporary file with current content
  local temp_file = create_temp_file('memo', '.md')
  local content = memo.content or ''

  -- Write current content to temp file
  local success, err = lc.fs.write_file_sync(temp_file, content)
  if not success then
    lc.notify('Failed to create temp file: ' .. tostring(err or 'Unknown error'))
    return
  end

  -- Open editor with the temp file
  lc.interactive({ config.editor, temp_file }, function(exit_code)
    lc.log('debug', 'Editor exited with code: {}', exit_code)

    -- Read edited content
    local new_content, read_err = lc.fs.read_file_sync(temp_file)
    if not new_content then
      lc.log('error', 'Failed to read temp file: {}', read_err or 'Unknown')
      lc.notify 'Error: Failed to read edited content'
      return
    end

    -- Check if content was changed
    if new_content == content then
      lc.notify 'No changes made'
      return
    end

    -- Update memo via API
    lc.log('info', 'Updating memo #{} to {}', memo.id, new_content)

    api_call('PATCH', '/memos/' .. memo.id, {
      content = new_content,
    }, function(res)
      if not res.success then
        lc.notify('Failed to update memo: ' .. tostring(res.error or 'Unknown error'))
        return
      end

      lc.notify 'Memo updated successfully'

      -- Reload the list to show updated content
      lc.cmd 'reload'
    end)

    -- Clean up temp file
    os.remove(temp_file)
  end)
end

-- Copy the content of currently selected memo to clipboard
local function yank_current_memo()
  local entry = lc.api.page_get_hovered()

  if not entry or not entry.memo or not entry.memo.content then
    lc.notify 'No memo selected'
    lc.log('warn', 'No memo selected for yanking')
    return
  end

  local memo = entry.memo

  lc.log('info', 'Yanking memo #{} content', memo.id)

  -- Copy content to clipboard using OSC 52
  local success, err = pcall(lc.osc52_copy, memo.content:trim())

  if not success then
    lc.notify('Failed to copy: ' .. tostring(err))
  else
    lc.notify 'Copied to clipboard'
  end
end

-- Delete the currently selected memo
local function delete_current_memo()
  local entry = lc.api.page_get_hovered()

  if not entry then
    lc.notify 'No memo selected'
    lc.log('warn', 'No memo selected for deletion')
    return
  end

  local memo = entry.memo

  -- Show confirmation dialog before deleting
  lc.confirm {
    prompt = 'Delete this memo?',
    on_confirm = function()
      api_call('DELETE', '/memos/' .. memo.id, nil, function(res)
        if not res.success then
          lc.notify('Failed to delete memo: ' .. tostring(res.error or 'Unknown error'))
          return
        end

        lc.notify('Memo deleted successfully: ' .. memo.id)
        lc.cmd 'reload'
      end)
    end,
  }
end

-- Create a new memo using external editor
local function create_new_memo()
  local temp_file = create_temp_file('new_memo', '.md')
  local template = ''
  lc.fs.write_file_sync(temp_file, template)

  -- Open editor
  lc.interactive({ config.editor, temp_file }, function(exit_code)
    lc.log('debug', 'Editor exited with code: {}', exit_code)

    -- Read edited content
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

    api_call('POST', '/memos', {
      content = content,
      visibility = config.visibility,
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
      lc.cmd 'scroll_by -9999' -- 返回顶部
    end)
  end)
end

function M.setup(opt)
  config = lc.tbl_extend(config, opt or {})
  lc.keymap.set('main', 'n', create_new_memo)
  lc.keymap.set('main', 'y', yank_current_memo)
  lc.keymap.set('main', '<C-e>', edit_current_memo)
  lc.keymap.set('main', '<enter>', edit_current_memo)
  lc.keymap.set('main', 'dd', delete_current_memo)
end

function M.list(_, cb)
  lc.log('info', 'Loading memos list')
  lc.api.page_set_preview 'Loading memos...'

  api_call('GET', '/memos?state=NORMAL&pageSize=100', nil, function(res)
    if not res.success then
      lc.notify('Error: ' .. tostring(res.error or 'Unknown error'))
      return
    end

    -- Parse JSON response
    local memos = lc.json.decode(res.body)

    -- Handle error response from memos API
    if type(memos) ~= 'table' or #memos.memos == 0 then
      lc.notify 'No memos found'
      cb {}
      return
    end

    -- Convert memos to PageEntry format
    local entries = {}
    for _, memo in ipairs(memos.memos) do
      local content = memo.content or ''
      memo.id = memo.name:sub(7)
      local display_parts = {}

      -- 解析创建时间并格式化为 compact 格式（黄色）
      if memo.createTime then
        local success, parsed = pcall(lc.time.parse, memo.createTime)
        if success then
          memo.timestamp = parsed
          table.insert(display_parts, lc.time.format(memo.timestamp, 'compact'):fg 'yellow')
          table.insert(display_parts, ' ')
        end
      end

      -- 添加内容预览（绿色）
      local display_title = content:utf8_sub(1, 60)
      if #content > 60 then display_title = display_title .. '...' end
      table.insert(display_parts, display_title:fg 'green')

      table.insert(entries, {
        key = tostring(memo.id),
        display = lc.style.line(display_parts),
        memo = memo, -- Store full memo data for preview
      })
    end

    lc.log('info', 'Loaded {} memos entries', #entries)
    cb(entries)
  end)
end

-- Format timestamp to readable date
local function format_timestamp(ts)
  if not ts then return 'Unknown' end

  -- Use lc.time.parse to parse ISO 8601 format
  local success, timestamp = pcall(lc.time.parse, ts)
  if success and timestamp then
    -- Format timestamp as local time
    return os.date('%Y-%m-%d %H:%M:%S', timestamp)
  end

  -- Fallback to original string if parsing fails
  return ts
end

-- Build rich preview text for a memo
local function build_preview(memo)
  local lines = {}

  -- Meta info
  table.insert(lines, lc.style.line { ('📝 '):fg 'cyan', ('Metadata'):fg 'cyan' })
  table.insert(lines, lc.style.line { ('   ID:           '):fg 'cyan', (memo.id or ''):fg 'yellow' })
  table.insert(lines, lc.style.line { ('   State:        '):fg 'cyan', (memo.state or 'UNKNOWN'):fg 'blue' })
  table.insert(lines, lc.style.line { ('   Visibility:   '):fg 'cyan', (memo.visibility or 'PRIVATE'):fg 'magenta' })
  table.insert(lines, lc.style.line { ('   Created:      '):fg 'cyan', format_timestamp(memo.createTime):fg 'green' })
  table.insert(lines, lc.style.line { ('   Updated:      '):fg 'cyan', format_timestamp(memo.updateTime):fg 'green' })

  -- Pinned status
  if memo.pinned then table.insert(lines, lc.style.line { ('   '):fg 'cyan', ('📌 Pinned'):fg 'yellow' }) end

  -- Tags
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

  -- Attachments
  if memo.attachments and #memo.attachments > 0 then
    table.insert(
      lines,
      lc.style.line {
        ('   '):fg 'cyan',
        ('📎 '):fg 'yellow',
        ('Attachments: '):fg 'cyan',
        tostring(#memo.attachments):fg 'yellow',
      }
    )
  end

  -- Relations
  if memo.relations and #memo.relations > 0 then
    table.insert(
      lines,
      lc.style.line {
        ('   '):fg 'cyan',
        ('🔗 '):fg 'blue',
        ('Relations:   '):fg 'cyan',
        tostring(#memo.relations):fg 'blue',
      }
    )
  end

  -- Reactions
  if memo.reactions and #memo.reactions > 0 then
    table.insert(
      lines,
      lc.style.line {
        ('   '):fg 'cyan',
        ('❤️  '):fg 'red',
        ('Reactions:  '):fg 'cyan',
        tostring(#memo.reactions):fg 'red',
      }
    )
  end

  -- Properties
  table.insert(lines, '')
  table.insert(lines, lc.style.line { ('⚙️ '):fg 'cyan', ('Properties'):fg 'cyan' })
  if memo.property then
    local props = {}
    if memo.property.hasLink then table.insert(props, ('links'):fg 'blue') end
    if memo.property.hasTaskList then table.insert(props, ('tasks'):fg 'green') end
    if memo.property.hasCode then table.insert(props, ('code'):fg 'magenta') end
    if memo.property.hasIncompleteTasks then table.insert(props, ('incomplete_tasks'):fg 'yellow') end
    if #props > 0 then
      local prop_parts = {}
      table.insert(prop_parts, '   ')
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

  -- Content
  table.insert(lines, '')
  table.insert(lines, lc.style.line { ('📄 '):fg 'cyan', ('Content'):fg 'cyan' })
  table.insert(lines, '')
  table.insert(lines, memo.content or '(no content)')

  return lc.style.text(lines)
end

function M.preview(entry, cb) cb(build_preview(entry.memo)) end

return M
