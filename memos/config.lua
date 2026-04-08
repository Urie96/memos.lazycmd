local M = {}

local cfg = {
  token = '',
  base_url = '',
  visibility = 'PRIVATE',
  keymap = {
    new = 'n',
    copy = 'y',
    edit = '<C-e>',
    open = '<enter>',
    delete = 'dd',
  },
}

function M.setup(opt)
  cfg = lc.tbl_deep_extend('force', cfg, opt or {})
end

function M.get() return cfg end

return M
