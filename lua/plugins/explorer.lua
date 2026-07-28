-- Helper: find closest git parent for any path
local function get_git_root(path)
  if not path or path == "" then
    return nil
  end
  local uv = vim.uv or vim.loop
  local dir = uv.fs_stat(path) and uv.fs_stat(path).type == "directory" and path or vim.fn.fnamemodify(path, ":h")
  while dir and dir ~= "/" and dir ~= "" do
    if uv.fs_stat(dir .. "/.git") then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

-- Get git root from explorer's focused item or current buffer
local function get_context_git_root()
  local ok, picker_mod = pcall(require, "snacks.picker")
  if ok then
    local pickers = picker_mod.get({ source = "explorer" })
    for _, picker in ipairs(pickers) do
      local current = picker.list and picker.list:current()
      if current and current.file then
        return get_git_root(current.file)
      end
    end
  end
  return get_git_root(vim.fn.expand("%:p"))
end

local function setup_multirepo()
  local ok, Git = pcall(require, "snacks.explorer.git")
  if not ok or type(Git.update) ~= "function" then
    return
  end

  local git_root_cache = {}
  local status_cache = {}

  local function find_git_roots(cwd)
    local now = os.time()
    local cached = git_root_cache[cwd]
    if cached and now < cached.expires then
      return cached.roots
    end

    local roots = {}
    local uv = vim.uv or vim.loop

    if uv.fs_stat(cwd .. "/.git") then
      roots[cwd] = true
    end

    local handle = uv.fs_scandir(cwd)
    if handle then
      while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then
          break
        end
        if ftype == "directory" and name ~= ".git" then
          local child = cwd .. "/" .. name
          if uv.fs_stat(child .. "/.git") then
            roots[child] = true
          end
        end
      end
    end

    local parent_root = get_git_root(cwd)
    if parent_root then
      roots[parent_root] = true
    end

    git_root_cache[cwd] = { roots = roots, expires = now + 60 }
    return roots
  end

  local function run_git_status(root, opts, callback)
    local uv = vim.uv or vim.loop
    local output = ""
    local stdout = assert(uv.new_pipe())

    local handle
    handle = uv.spawn("git", {
      stdio = { nil, stdout, nil },
      cwd = root,
      hide = true,
      args = {
        "--no-pager",
        "--no-optional-locks",
        "status",
        "--porcelain=v1",
        "--ignored=matching",
        "-z",
        opts.untracked and "-unormal" or "-uno",
      },
    }, function()
      if handle then
        handle:close()
      end
    end)

    if not handle then
      callback({})
      return
    end

    stdout:read_start(function(err, data)
      assert(not err, err)
      if data then
        output = output .. data
      else
        stdout:close()
        local ret = {}
        for _, line in ipairs(vim.split(output, "\0")) do
          if line ~= "" then
            local status, file = line:match("^(..) (.*)$")
            if status then
              ret[#ret + 1] = { status = status, file = root .. "/" .. file }
            end
          end
        end
        status_cache[root] = ret
        callback(ret)
      end
    end)
  end

  -- Patch Git.update for multi-repo – NO call to original update
  local original_update = Git.update
  function Git.update(cwd, opts)
    opts = opts or {}
    local ttl = opts.ttl or (15 * 60)
    if opts.force then
      ttl = 0
    end

    local roots = find_git_roots(cwd)
    local root_list = vim.tbl_keys(roots)

    if #root_list == 0 then
      -- Fall back to original single‑repo behaviour
      return original_update(cwd, opts)
    end

    local now = os.time()
    local pending = #root_list
    local all_results = {}

    local function on_complete()
      pending = pending - 1
      if pending > 0 then
        return
      end

      -- Merge all sub‑repo results
      local merged = {}
      for _, results in pairs(all_results) do
        for _, r in ipairs(results) do
          merged[#merged + 1] = r
        end
      end

      -- Directly update the git state for the main cwd,
      -- exactly as the original would have done for a single repo.
      Git.state[cwd] = Git.state[cwd] or {}
      local state = Git.state[cwd]
      state.status = merged
      state.last = now
      state.tick = (state.tick or 0) + 1

      -- Fire the user callback (explorer uses this to re‑render)
      if opts.on_update then
        vim.schedule(opts.on_update)
      end
    end

    for _, root in ipairs(root_list) do
      Git.state[root] = Git.state[root] or { tick = 0, last = 0 }
      local state = Git.state[root]

      if now - state.last < ttl and status_cache[root] then
        all_results[root] = status_cache[root]
        on_complete()
      else
        state.last = now
        state.tick = state.tick + 1
        run_git_status(root, opts, function(results)
          all_results[root] = results
          on_complete()
        end)
      end
    end
  end

  -- Patch Git.refresh – keep it straightforward
  local original_refresh = Git.refresh
  Git.refresh = function(path)
    original_refresh(path)
    for root in pairs(Git.state) do
      if path == root or path:find(root .. "/", 1, true) == 1 then
        Git.state[root].last = 0
        status_cache[root] = nil
      end
    end
    git_root_cache = {}
  end

  -- Patch picker actions (unchanged, still correct)
  local Actions = require("snacks.picker.actions")
  local function with_git_root(original_fn)
    return function(picker, ...)
      local items = picker:selected({ fallback = true })
      for _, item in ipairs(items) do
        if item.file and not item.cwd then
          item.cwd = get_git_root(item.file)
        end
      end
      return original_fn(picker, ...)
    end
  end

  Actions.git_stage = with_git_root(Actions.git_stage)
  Actions.git_restore = with_git_root(Actions.git_restore)
  if Actions.git_stash_apply then
    Actions.git_stash_apply = with_git_root(Actions.git_stash_apply)
  end
  if Actions.git_checkout then
    Actions.git_checkout = with_git_root(Actions.git_checkout)
  end

  -- Patch Picker.pick / LazyGit.open (unchanged)
  local Picker = require("snacks.picker")
  local original_pick = Picker.pick
  local git_sources = {
    git_status = true,
    git_log = true,
    git_diff = true,
    git_branches = true,
    git_stash = true,
    git_files = true,
  }

  Picker.pick = function(source, opts)
    if type(source) == "string" and git_sources[source] then
      opts = opts or {}
      local context_root = get_context_git_root()
      if context_root then
        opts.cwd = context_root
      end
    end
    return original_pick(source, opts)
  end

  local LazyGit = require("snacks.lazygit")
  local original_lazygit_open = LazyGit.open
  LazyGit.open = function(opts)
    opts = opts or {}
    local context_root = get_context_git_root()
    if context_root then
      opts.cwd = context_root
    end
    return original_lazygit_open(opts)
  end
end

return {
  "folke/snacks.nvim",
  opts = { explorer = { enabled = true, auto_open = false } },
  config = function(_, opts)
    require("snacks").setup(opts)
    setup_multirepo()
  end,
  keys = {
    {
      "<leader>e",
      function()
        Snacks.explorer({ cwd = vim.fn.getcwd() })
      end,
      desc = "Explorer (cwd)",
    },
    {
      "<leader>fe",
      function()
        Snacks.explorer({ cwd = vim.fn.getcwd() })
      end,
      desc = "Explorer (cwd)",
    },
    {
      "<leader>E",
      function()
        local r = get_git_root(vim.fn.expand("%:p"))
        Snacks.explorer({ cwd = r or vim.fn.expand("%:p:h") })
      end,
      desc = "Explorer (buffer root)",
    },
    {
      "<leader>FE",
      function()
        local r = get_git_root(vim.fn.expand("%:p"))
        Snacks.explorer({ cwd = r or vim.fn.expand("%:p:h") })
      end,
      desc = "Explorer (buffer root)",
    },
  },
}
