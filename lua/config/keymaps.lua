-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
-- One shared Snacks terminal everywhere, regardless of :lcd / window cwd
local function shared_term()
  Snacks.terminal(nil, {
    cwd = (vim.uv or vim.loop).cwd(), -- global process cwd, not window-local
    count = 1, -- fixed id
  })
end

for _, lhs in ipairs({ "<C-/>", "<C-_>" }) do
  pcall(vim.keymap.del, { "n", "t" }, lhs)

  vim.keymap.set("n", lhs, shared_term, { silent = true, desc = "Terminal (shared)" })

  -- terminal buffers: override buffer-local LazyVim mapping after it is applied
  vim.api.nvim_create_autocmd({ "TermOpen", "TermEnter" }, {
    callback = function(ev)
      vim.schedule(function()
        pcall(vim.keymap.del, "t", lhs, { buffer = ev.buf })
        vim.keymap.set("t", lhs, shared_term, {
          buffer = ev.buf,
          silent = true,
          nowait = true,
          desc = "Terminal (shared)",
        })
      end)
    end,
  })
end
