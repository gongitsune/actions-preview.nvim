local backend = require("actions-preview.backend")
local config = require("actions-preview.config")
local Action = require("actions-preview.action").Action

local M = {}

-- based on https://github.com/neovim/neovim/blob/v0.8.0/runtime/lua/vim/lsp/buf.lua#L153-L178
---@private
---@param bufnr integer
---@param mode "v"|"V"
---@return table {start={row, col}, end={row, col}} using (1, 0) indexing
local function range_from_selection(bufnr, mode)
  -- TODO: Use `vim.region()` instead https://github.com/neovim/neovim/pull/13896

  -- [bufnum, lnum, col, off]; both row and column 1-indexed
  local start = vim.fn.getpos("v")
  local end_ = vim.fn.getpos(".")
  local start_row = start[2]
  local start_col = start[3]
  local end_row = end_[2]
  local end_col = end_[3]

  -- A user can start visual selection at the end and move backwards
  -- Normalize the range to start < end
  if start_row == end_row and end_col < start_col then
    end_col, start_col = start_col, end_col
  elseif end_row < start_row then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  if mode == "V" then
    start_col = 1
    local lines = vim.api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, true)
    end_col = #lines[1]
  end

  return {
    ["start"] = { start_row, start_col - 1 },
    ["end"] = { end_row, end_col - 1 },
  }
end

---@return lsp.DiagnosticSeverity
local function severity_vim_to_lsp(severity)
  if type(severity) == 'string' then
    severity = vim.diagnostic.severity[severity]
  end
  return severity
end

--- @param diagnostic vim.Diagnostic
--- @return lsp.DiagnosticTag[]?
local function tags_vim_to_lsp(diagnostic)
  if not diagnostic._tags then
    return
  end

  local tags = {} --- @type lsp.DiagnosticTag[]
  if diagnostic._tags.unnecessary then
    tags[#tags + 1] = vim.lsp.protocol.DiagnosticTag.Unnecessary
  end
  if diagnostic._tags.deprecated then
    tags[#tags + 1] = vim.lsp.protocol.DiagnosticTag.Deprecated
  end
  return tags
end

--- @param diagnostics vim.Diagnostic[]
--- @return lsp.Diagnostic[]
local function diagnostic_vim_to_lsp(diagnostics)
  ---@param diagnostic vim.Diagnostic
  ---@return lsp.Diagnostic
  return vim.tbl_map(function(diagnostic)
    return vim.tbl_extend('keep', {
      -- "keep" the below fields over any duplicate fields in diagnostic.user_data.lsp
      range = {
        start = {
          line = diagnostic.lnum,
          character = diagnostic.col,
        },
        ['end'] = {
          line = diagnostic.end_lnum,
          character = diagnostic.end_col,
        },
      },
      severity = severity_vim_to_lsp(diagnostic.severity),
      message = diagnostic.message,
      source = diagnostic.source,
      code = diagnostic.code,
      tags = tags_vim_to_lsp(diagnostic),
    }, diagnostic.user_data and (diagnostic.user_data.lsp or {}) or {})
  end, diagnostics)
end

local function on_code_action_results(results, opts)
  -- based on https://github.com/neovim/neovim/blob/v0.10.0/runtime/lua/vim/lsp/buf.lua#L705-L731
  local function action_filter(a)
    -- filter by specified action kind
    if opts and opts.context and opts.context.only then
      if not a.kind then
        return false
      end
      local found = false
      for _, o in ipairs(opts.context.only) do
        -- action kinds are hierarchical with . as a separator: when requesting only 'type-annotate'
        -- this filter allows both 'type-annotate' and 'type-annotate.foo', for example
        if a.kind == o or vim.startswith(a.kind, o .. ".") then
          found = true
          break
        end
      end
      if not found then
        return false
      end
    end
    -- filter by user function
    if opts and opts.filter and not opts.filter(a) then
      return false
    end
    -- no filter removed this action
    return true
  end

  local actions = {}
  for _, result in pairs(results) do
    for _, action in pairs(result.result or {}) do
      if action_filter(action) then
        table.insert(actions, Action.new(result.ctx, action))
      end
    end
  end
  if #actions == 0 then
    vim.notify("No code actions available", vim.log.levels.INFO)
    return
  end

  if opts and opts.apply and #actions == 1 then
    actions[1]:apply()
    return
  end
  backend.select(config, actions)
end

function M.setup(opts)
  config.setup(opts)
end

-- based on https://github.com/neovim/neovim/blob/v0.10.0/runtime/lua/vim/lsp/buf.lua#L824-L891
--- Selects a code action available at the current
--- cursor position.
---
-- ---@param opts? vim.lsp.buf.code_action.Opts
---@see https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
---@see vim.lsp.protocol.CodeActionTriggerKind
function M.code_actions(opts)
  vim.validate({ options = { opts, "t", true } })
  opts = opts or {}
  -- Detect old API call code_action(context) which should now be
  -- code_action({ context = context} )
  --- @diagnostic disable-next-line:undefined-field
  if opts.diagnostics or opts.only then
    opts = { options = opts }
  end
  local context = opts.context or {}
  if not context.triggerKind and vim.lsp.protocol.CodeActionTriggerKind then
    context.triggerKind = vim.lsp.protocol.CodeActionTriggerKind.Invoked
  end
  if not context.diagnostics then
    local bufnr = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1] - 1
    context.diagnostics = diagnostic_vim_to_lsp(vim.diagnostic.get(bufnr, { lnum = line }))
  end
  local mode = vim.api.nvim_get_mode().mode
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/codeAction" })
  local remaining = #clients
  if remaining == 0 then
    if next(vim.lsp.get_clients({ bufnr = bufnr })) then
      vim.notify("code action is not supported by the server", vim.log.levels.WARN)
    end
    return
  end

  -- ---@type table<integer, vim.lsp.CodeActionResultEntry>
  local results = {}

  -- ---@param err? lsp.ResponseError
  -- ---@param result? (lsp.Command|lsp.CodeAction)[]
  -- ---@param ctx lsp.HandlerContext
  local function on_result(err, result, ctx)
    results[ctx.client_id] = { error = err, result = result, ctx = ctx }
    remaining = remaining - 1
    if remaining == 0 then
      on_code_action_results(results, opts)
    end
  end

  for _, client in ipairs(clients) do
    -- ---@type lsp.CodeActionParams
    local params
    if opts.range then
      assert(type(opts.range) == "table", "code_action range must be a table")
      local start = assert(opts.range.start, "range must have a `start` property")
      local end_ = assert(opts.range["end"], "range must have a `end` property")
      params = vim.lsp.util.make_given_range_params(start, end_, bufnr, client.offset_encoding)
    elseif mode == "v" or mode == "V" then
      local range = range_from_selection(bufnr, mode)
      params =
          vim.lsp.util.make_given_range_params(range.start, range["end"], bufnr, client.offset_encoding)
    else
      params = vim.lsp.util.make_range_params(win, client.offset_encoding)
    end
    params.context = context
    client.request("textDocument/codeAction", params, on_result, bufnr)
  end
end

return M
