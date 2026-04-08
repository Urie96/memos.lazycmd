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
  local entry = lc.api.get_hovered()
  if not entry or entry.kind ~= 'memo' or not entry.memo then return nil end
  return entry
end

local function format_timestamp(ts)
  if not ts then return 'Unknown' end
  local success, timestamp = pcall(lc.time.parse, ts)
  if success and timestamp then return os.date('%Y-%m-%d %H:%M:%S', timestamp) end
  return ts
end

local function format_bytes(size)
  local n = tonumber(size)
  if not n then return tostring(size or '?') end
  if n < 1024 then return string.format('%d B', n) end
  if n < 1024 * 1024 then return string.format('%.1f KB', n / 1024) end
  if n < 1024 * 1024 * 1024 then return string.format('%.1f MB', n / (1024 * 1024)) end
  return string.format('%.1f GB', n / (1024 * 1024 * 1024))
end

local function is_image_attachment(attachment)
  local mime = tostring((attachment or {}).type or ''):lower()
  return mime:match '^image/' ~= nil
end

local IMAGE_CACHE_DIR = (os.getenv 'HOME' or '/tmp') .. '/.cache/lazycmd/memos-images'

local function attachment_image_url(attachment)
  if not is_image_attachment(attachment) then return nil end

  if attachment.externalLink and attachment.externalLink ~= '' then return attachment.externalLink end

  if cfg and cfg.base_url and attachment.name and attachment.filename then
    return string.format('%s/file/%s/%s', cfg.base_url, attachment.name, attachment.filename)
  end

  return nil
end

local function cached_image_path(url, filename, attachment)
  local ext = tostring(filename or ''):match '%.([^.]+)$' or 'img'
  local raw_key = tostring((attachment or {}).name or '')
  raw_key = raw_key:match('attachments/(.+)$') or raw_key
  if raw_key == '' then raw_key = tostring(filename or 'image') end
  raw_key = raw_key:gsub('[^%w._-]', '_')
  return string.format('%s/%s.%s', IMAGE_CACHE_DIR, raw_key, ext)
end

local function attachment_preview_image(attachment)
  local url = attachment_image_url(attachment)
  if not url then return nil end

  local path = cached_image_path(url, attachment.filename, attachment)
  local stat = lc.fs.stat(path)
  if stat and stat.exists and stat.is_file and (stat.size or 0) > 128 then return lc.style.image(path) end

  return nil
end

local function prefetch_attachment_image(attachment, done)
  local url = attachment_image_url(attachment)
  if not url then
    if done then done(false) end
    return
  end

  local path = cached_image_path(url, attachment.filename, attachment)
  local stat = lc.fs.stat(path)
  if stat and stat.exists and stat.is_file and (stat.size or 0) > 128 then
    if done then done(true) end
    return
  end

  if stat and stat.exists and stat.is_file then lc.fs.remove(path) end

  lc.fs.mkdir(IMAGE_CACHE_DIR)

  local cmd = { 'curl', '-k', '-L', '-sS' }
  if cfg and cfg.token and cfg.token ~= '' then
    table.insert(cmd, '-H')
    table.insert(cmd, 'Authorization: Bearer ' .. cfg.token)
  end
  table.insert(cmd, '-o')
  table.insert(cmd, path)
  table.insert(cmd, url)

  lc.system.exec(cmd, function(output)
    local ok = output and output.code == 0
    local new_stat = lc.fs.stat(path)
    ok = ok and new_stat and new_stat.exists and new_stat.is_file and (new_stat.size or 0) > 128
    if not ok and new_stat and new_stat.exists and new_stat.is_file then lc.fs.remove(path) end
    if done then done(ok) end
  end)
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
  local preview_parts = {}
  table.insert(lines, lc.style.line { ('󰦨 '):fg 'cyan', ('Metadata'):fg 'cyan' })
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
      ('   Attachments: '):fg 'cyan',
    })
    for _, attachment in ipairs(memo.attachments) do
      local filename = attachment.filename or attachment.name or '(unnamed)'
      local mime = attachment.type or 'unknown'
      local size = attachment.size and format_bytes(attachment.size) or nil

      local parts = {
        ('     • '):fg 'dark_gray',
        tostring(filename):fg 'yellow',
        ('  '):fg 'cyan',
        tostring(mime):fg 'magenta',
      }
      if size then
        table.insert(parts, ('  '):fg 'cyan')
        table.insert(parts, tostring(size):fg 'green')
      end
      table.insert(lines, lc.style.line(parts))

      if attachment.externalLink and attachment.externalLink ~= '' then
        table.insert(lines, lc.style.line {
          ('       ↳ '):fg 'dark_gray',
          tostring(attachment.externalLink):fg 'blue',
        })
      end
    end
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
      ('   Reactions:  '):fg 'cyan',
    })
    for _, reaction in ipairs(memo.reactions) do
      local reaction_type = reaction.reactionType or '?'
      local creator = reaction.creator or ''
      creator = creator:match('users/(.+)$') or creator
      table.insert(lines, lc.style.line {
        ('     • '):fg 'dark_gray',
        tostring(reaction_type):fg 'red',
        ('  '):fg 'cyan',
        tostring(creator):fg 'yellow',
      })
    end
  end

  table.insert(lines, '')
  table.insert(lines, lc.style.line { ('󰒓 '):fg 'cyan', ('Properties'):fg 'cyan' })
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
  table.insert(lines, lc.style.line { ('󰈙 '):fg 'cyan', ('Content'):fg 'cyan' })
  table.insert(lines, '')

  local content = memo.content or '(no content)'
  local highlighted = lc.style.highlight(content, 'markdown')

  table.insert(preview_parts, lc.style.text(lines))

  if memo.attachments and #memo.attachments > 0 then
    for _, attachment in ipairs(memo.attachments) do
      local image = attachment_preview_image(attachment)
      if image then
        table.insert(preview_parts, '')
        table.insert(preview_parts, lc.style.line {
          ('󰋩 '):fg 'cyan',
          tostring(attachment.filename or 'Image'):fg 'yellow',
        })
        table.insert(preview_parts, image)
      end
    end
  end

  table.insert(preview_parts, highlighted)

  return preview_parts
end

function M.memo_preview(entry, cb)
  local memo = entry.memo or {}
  local has_remote_images = false

  if memo.attachments and #memo.attachments > 0 then
    for _, attachment in ipairs(memo.attachments) do
      if attachment_image_url(attachment) and not attachment_preview_image(attachment) then
        has_remote_images = true
        break
      end
    end
  end

  cb(M.build_preview(memo))

  if not has_remote_images then return end

  local pending = 0
  local refreshed = false
  local function maybe_refresh()
    if refreshed or pending > 0 then return end
    refreshed = true
    cb(M.build_preview(memo))
  end

  for _, attachment in ipairs(memo.attachments or {}) do
    if attachment_image_url(attachment) and not attachment_preview_image(attachment) then
      pending = pending + 1
      prefetch_attachment_image(attachment, function(_)
        pending = pending - 1
        maybe_refresh()
      end)
    end
  end
end

function M.info_preview(entry)
  return lc.style.text {
    lc.style.line { (entry.title or 'memos'):fg 'cyan' },
    lc.style.line { (entry.message or ''):fg(entry.color or 'darkgray') },
    lc.style.line { (entry.detail or ''):fg 'darkgray' },
  }
end

return M
